import {
  Accessory,
  AudioBitrate,
  AudioRecordingCodecType,
  AudioRecordingSamplerate,
  AudioStreamingCodecType,
  AudioStreamingSamplerate,
  CameraController,
  Categories,
  Characteristic,
  H264Level,
  H264Profile,
  HAPStorage,
  MediaContainerType,
  SRTPCryptoSuites,
  Service,
  VideoCodecType,
  uuid,
} from "@homebridge/hap-nodejs";
import { execFile, execFileSync, spawn } from "node:child_process";
import { createSocket } from "node:dgram";
import { EventEmitter } from "node:events";
import { createInterface } from "node:readline";
import { mkdirSync, readFileSync } from "node:fs";
import { networkInterfaces } from "node:os";
import { dirname, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";

const DEFAULT_PIN = "031-45-154";
const DEFAULT_USERNAME = "A2:44:5A:11:00:06";
const FFMPEG_H264_PROFILES = ["baseline", "main", "high"];
// HAP-NodeJS 2.1.7 defines only these three HAP level identifiers.
// Values 3/4 are NOT documented mappings for AVC levels 5.0/5.1.
const FFMPEG_H264_LEVELS = ["3.1", "3.2", "4.0"];

const allocatedPorts = new Set();

function log(level, subsystem, message, extra = undefined) {
  const payload = {
    ts: new Date().toISOString(),
    level,
    subsystem,
    message,
    ...(extra ? { extra } : {}),
  };
  process.stderr.write(`${JSON.stringify(payload)}\n`);
}

function isJPEG(buffer) {
  return Buffer.isBuffer(buffer) && buffer.length > 2 && buffer[0] === 0xff && buffer[1] === 0xd8;
}

function sanitizeForLog(value) {
  return String(value)
    .replace(/(rtsp:\/\/[^:/\s]+:)[^@\s]+@/gi, "$1***@")
    .replace(/(password=)[^&\s]+/gi, "$1***");
}

// Probe actual main-stream properties, independently of the GUI preview profile.
// A failed probe is unknown, never an invented H.264/4K source.
export async function probeVideoSource(config) {
  const ffprobe = config.ffmpegPath.replace(/ffmpeg(\b|$)/, "ffprobe");
  try {
    const { stdout } = await promisify(execFile)(ffprobe, [
      "-v", "error", "-rtsp_transport", "tcp", "-timeout", "6000000",
      "-analyzeduration", "1000000", "-probesize", "2000000",
      "-i", config.rtspUrl, "-select_streams", "v:0",
      "-show_entries", "stream=codec_name,width,height,avg_frame_rate,r_frame_rate,profile,level,bit_rate",
      "-of", "json",
    ], { encoding: "utf8", timeout: 12_000, maxBuffer: 256 * 1024 });
    const stream = JSON.parse(stdout).streams?.[0];
    if (!stream?.width || !stream?.height || !stream?.codec_name) return undefined;
    const [n, d] = (stream.avg_frame_rate || stream.r_frame_rate || "0/1").split("/").map(Number);
    return { codec: stream.codec_name, width: stream.width, height: stream.height,
      fps: d ? n / d : 0, profile: stream.profile, level: stream.level };
  } catch {
    return undefined;
  }
}

function loadConfig() {
  const configPath = process.env.HOMELENS_BRIDGE_CONFIG;
  if (!configPath) {
    throw new Error("HOMELENS_BRIDGE_CONFIG is required.");
  }
  const config = JSON.parse(readFileSync(configPath, "utf8"));
  config.rtspUrl ||= process.env.HOMELENS_RTSP_URL;
  config.rtspSubUrl ||= process.env.HOMELENS_RTSP_SUB_URL;
  if (!config.name || !config.rtspUrl) {
    throw new Error("Bridge config must include name and rtspUrl or HOMELENS_RTSP_URL.");
  }
  config.pin ||= DEFAULT_PIN;
  config.username ||= DEFAULT_USERNAME;
  config.ffmpegPath ||= process.env.FFMPEG_PATH || "ffmpeg";
  config.storagePath ||= resolve(dirname(configPath), "hap-storage");
  config.interfaceName ||= undefined;
  config.video ||= {};
  config.video.width ||= 1920;
  config.video.height ||= 1080;
  config.video.fps ||= 15;
  config.video.maxBitrateKbps ||= 2048;
  config.video.packetSize ||= 1316;
  config.video.directCopy = config.video.directCopy !== false;
  config.video.qualityMode ||= "adaptive";
  config.audio ||= {};
  config.audio.enabled = config.audio.enabled !== false;
  config.audio.codec ||= "opus";
  config.audio.bitrateKbps ||= 24;
  config.audio.sampleRate ||= 16000;
  config.recording ||= {};
  config.recording.quality ||= "compatible";
  if (!["native", "compatible"].includes(config.recording.quality)) {
    throw new Error("recording.quality must be native or compatible");
  }
  config.recording.enabled = config.recording.enabled !== false;
  config.recording.prebufferMs ||= 4000;
  config.recording.fragmentMs ||= 4000;
  // Safety net only: the hub closes clips itself. Ending a clip while motion is
  // still active is never acknowledged; HAP-NodeJS then force-closes it with
  // CANCELLED 12 s later (observed as 32 s clips with a 20 s cap).
  config.recording.maxSeconds ||= 600;
  config.recording.stallTimeoutMs ||= 20_000;
  return config;
}

// ffmpeg forwards RTP as soon as the camera delivers it, and the camera delivers
// in bursts (measured: up to 1.4 s without a packet, then a whole GOP). The
// controller's jitter buffer is far smaller, so playback cut out every burst even
// with smoothed timestamps. This relay sits between ffmpeg (loopback) and the
// controller: video packets leave on their RTP-timestamp schedule plus a delay
// that grows to the largest lateness observed (bounded); audio and RTCP follow
// the same delay so A/V alignment is unchanged. SRTP packets are opaque here, so
// nothing is re-encrypted or re-sequenced.
export class PacedRelay {
  constructor({ name, send, clockRate, delayProvider, initialDelayMs = 1000, maxDelayMs = 2500,
    paceBytesPerMs = 5000, now = Date.now }) {
    this.name = name;
    // A 4K keyframe is ~730 KB = 600+ packets sharing one timestamp. Sent at once
    // they overflow Wi-Fi/receiver queues (measured: 20-30 packets lost per burst),
    // so packets are spread at 40 Mbit/s: one keyframe over ~150 ms, P-frames in ms.
    this.paceBytesPerMs = paceBytesPerMs;
    this.lastBytes = 0;
    this.send = send;
    this.clockRate = clockRate;
    this.delayProvider = delayProvider;
    this.delayMs = initialDelayMs;
    this.maxDelayMs = maxDelayMs;
    this.now = now;
    this.queue = [];
    this.forwarded = 0;
    this.late = 0;
    this.closed = false;
  }

  get currentDelayMs() {
    return this.delayProvider ? this.delayProvider() : this.delayMs;
  }

  // Wall-clock instant at which this packet should leave.
  scheduleTime(packet, isRTCP) {
    const now = this.now();
    if (isRTCP || !this.clockRate || packet.length < 12) return now + this.currentDelayMs;
    const ts = packet.readUInt32BE(4);
    if (this.baseWall === undefined) {
      this.baseWall = now;
      this.lastTs = ts;
      this.offsetTicks = 0;
    } else {
      this.offsetTicks += (ts - this.lastTs) | 0; // signed delta survives 32-bit wrap
      this.lastTs = ts;
    }
    const ideal = this.baseWall + (this.offsetTicks * 1000) / this.clockRate;
    let target = ideal + this.currentDelayMs;
    if (target < now) {
      // The camera burst outran the jitter margin: send now and widen it.
      this.late += 1;
      if (!this.delayProvider) this.delayMs = Math.min(this.maxDelayMs, Math.round(now - ideal + 100));
      target = now;
    }
    return target;
  }

  // Single FIFO queue and one timer: packets can never overtake each other
  // (per-packet timers with different durations reordered same-frame packets).
  push(packet, isRTCP = false) {
    if (this.closed) return;
    const spacing = this.lastBytes / this.paceBytesPerMs;
    const target = Math.max(this.scheduleTime(packet, isRTCP), (this.lastTarget || 0) + spacing);
    this.lastTarget = target;
    this.lastBytes = packet.length;
    this.queue.push({ packet, isRTCP, target });
    this.arm();
  }

  arm() {
    if (this.timer || this.closed || !this.queue.length) return;
    const wait = Math.max(0, this.queue[0].target - this.now());
    this.timer = setTimeout(() => this.flush(), wait);
  }

  flush() {
    this.timer = undefined;
    if (this.closed) return;
    const now = this.now();
    while (this.queue.length && this.queue[0].target <= now) {
      const { packet, isRTCP } = this.queue.shift();
      this.forwarded += 1;
      this.send(packet, isRTCP);
    }
    this.arm();
  }

  close() {
    this.closed = true;
    clearTimeout(this.timer);
    this.timer = undefined;
    this.queue.length = 0;
  }
}

function openRelaySockets(relay, port) {
  const sockets = [];
  for (const [p, isRTCP] of [[port, false], [port + 1, true]]) {
    const socket = createSocket("udp4");
    socket.on("error", (error) => log("warning", "stream", `${relay.name} relay socket error: ${error.message}`));
    socket.on("message", (message) => relay.push(message, isRTCP));
    socket.bind(p, "127.0.0.1", () => {
      // A whole 4K GOP (~1.5 MB) can land within ~150 ms; the default receive
      // buffer would drop packets, which the controller sees as corrupt frames.
      for (const bytes of [4, 2, 1].map((mb) => mb * 1024 * 1024)) {
        try { socket.setRecvBufferSize(bytes); break; } catch { /* try smaller */ }
      }
    });
    sockets.push(socket);
  }
  return sockets;
}

function nextPort() {
  for (let port = 50110; port < 50998; port += 2) {
    if (!allocatedPorts.has(port) && !allocatedPorts.has(port + 1)) {
      allocatedPorts.add(port);
      allocatedPorts.add(port + 1);
      return port;
    }
  }
  throw new Error("No free local RTP ports left.");
}

function cleanAddress(address) {
  return String(address || "").replace(/^::ffff:/i, "").split("%")[0];
}

function isIPv4(address) {
  return /^\d{1,3}(?:\.\d{1,3}){3}$/.test(cleanAddress(address));
}

function sameIPv4Slash24(a, b) {
  const left = cleanAddress(a).split(".");
  const right = cleanAddress(b).split(".");
  return left.length === 4 && right.length === 4 &&
    left[0] === right[0] && left[1] === right[1] && left[2] === right[2];
}

function usableStreamTarget(request) {
  const target = cleanAddress(request.targetAddress);
  const remote = cleanAddress(request.remoteAddress);
  const local = cleanAddress(request.sourceAddress);
  if (isIPv4(target) && sameIPv4Slash24(target, local)) {
    return target;
  }
  if (isIPv4(remote) && sameIPv4Slash24(remote, local)) {
    return remote;
  }
  return target || remote;
}

function localIPv4ForTarget(target) {
  const cleanTarget = cleanAddress(target);
  let routedInterface;
  try {
    const route = execFileSync("/sbin/route", ["-n", "get", cleanTarget], {
      encoding: "utf8",
      timeout: 1000,
      stdio: ["ignore", "pipe", "ignore"],
    });
    routedInterface = route.match(/interface:\s*(\S+)/)?.[1];
  } catch {
    routedInterface = undefined;
  }
  if (routedInterface) {
    const routedAddresses = networkInterfaces()[routedInterface] || [];
    for (const address of routedAddresses) {
      const family = typeof address.family === "string" ? address.family : `IPv${address.family}`;
      if (family === "IPv4" && !address.internal && sameIPv4Slash24(address.address, cleanTarget)) {
        return address.address;
      }
    }
  }
  for (const addresses of Object.values(networkInterfaces())) {
    for (const address of addresses || []) {
      const family = typeof address.family === "string" ? address.family : `IPv${address.family}`;
      if (family !== "IPv4" || address.internal) {
        continue;
      }
      if (sameIPv4Slash24(address.address, cleanTarget)) {
        return address.address;
      }
    }
  }
  return undefined;
}

function usableLocalStreamAddress(request, targetAddress) {
  const source = cleanAddress(request.sourceAddress);
  if (request.addressVersion !== "ipv4") {
    return source;
  }
  // On a multi-homed Mac (e.g. two NICs on the same subnet), the interface the
  // HAP connection arrived on (request.sourceAddress) can differ from the one
  // RTP egresses toward the controller. Streaming from the "wrong" interface
  // makes the controller silently drop the video (no RTCP, black screen). Prefer
  // the local address that actually routes to the controller.
  const routed = localIPv4ForTarget(targetAddress);
  if (routed && routed !== source) {
    log("info", "stream", "using routed local interface for RTP (multi-homed host)", {
      hapSource: source,
      routed,
      target: targetAddress,
    });
    return routed;
  }
  if (isIPv4(source)) {
    return source;
  }
  return routed || source;
}

// Reolink RTSP timestamps follow the camera's send queue, not capture time: a
// large 4K keyframe is followed by a ~1.6 s timestamp jump, then a burst of
// P-frames spaced ~20 ms apart (measured on a CX810, see docs/VIDEO_PIPELINE.md).
// Players honouring those timestamps freeze and then race, and HomeKit reads the
// jitter as a poor network and renegotiates 360p at 132 kbit/s. Re-time video
// packets before decoding or copying: nominal cadence for the first K frames,
// then the mean output rate, steered toward the source clock with gain 1/K so
// bursts are spread out while long-term audio alignment is preserved. The state
// is anchored on the OUTPUT (origin 0 when the first packet has no timestamp,
// which is the case for the first RTSP keyframe) so a missing or absurd input
// timestamp can never poison the sequence. Packets are never dropped, reordered
// or re-encoded. Must precede -i (input-side bitstream filter).
export function smoothedTimestampArgs(fps) {
  const nominal = Number((fps > 0 ? fps : 25).toFixed(3));
  const k = Math.min(100, Math.max(20, Math.round(nominal * 2)));
  const missing = (v) => `gt(isnan(${v})+eq(${v},NOPTS),0)`;
  const origin = `if(${missing("STARTPTS")},0,STARTPTS)`;
  const mean = `if(lt(N,${k}),1/${nominal}/TB,(PREV_OUTPTS-${origin})/N)`;
  const steer = `if(${missing("PTS")},${mean}/${k},(PTS-PREV_OUTPTS)/${k})`;
  const expr = `if(eq(N,0),${origin},max(PREV_OUTPTS+1,PREV_OUTPTS+${steer}+${k - 1}/${k}*${mean}))`;
  return ["-bsf:v", `setts=ts='${expr}'`];
}

export function liveBitrateKbps(video) {
  // HomeKit's negotiated value is a ceiling, particularly important off-LAN.
  return Math.max(1, Math.round(video.max_bit_rate || 1600));
}

export function nativeLiveCopy(config, session) {
  // Original quality is explicitly enabled for Home 27. As with other HAP
  // bridges, legacy requested dimensions need not match the H.264 bitstream.
  // Keep remote sessions and HEVC sources on the negotiated H.264 encoder path.
  return config.recording.quality === "native" && config.sourceVideo?.codec === "h264"
    && isIPv4(session.address) && sameIPv4Slash24(session.address, session.localAddress);
}

class ReolinkStreamingDelegate {
  constructor(config) {
    this.config = config;
    this.pendingSessions = new Map();
    this.ongoingSessions = new Map();
    this.recordingActive = false;
    this.recordingConfiguration = undefined;
    this.prebuffer = undefined;
    this.controller = undefined;
    this.isMotionActive = () => false;
  }

  isRecordingAudioActive() {
    return this.config.audio.enabled !== false
      && this.controller?.recordingManagement?.recordingAudioActive === true;
  }

  handleSnapshotRequest(request, callback) {
    log("info", "snapshot", `snapshot requested ${request.width}x${request.height}`, {
      reason: request.reason,
    });
    // The Reolink HTTP Snap API on this firmware requires a token login and
    // answers inline user/password auth with a JSON error (HTTP 200) — and can
    // lock out logins. So snapshot from the RTSP stream (reliable, separate
    // auth). HTTP is only a last resort and must be a real JPEG to be trusted.
    this.tryRTSPSnapshot(request, (rtspError, image) => {
      if (!rtspError && image?.length) {
        log("debug", "snapshot", `RTSP snapshot ready bytes=${image.length}`);
        callback(undefined, image);
        return;
      }
      log("warning", "snapshot", `RTSP snapshot failed, trying HTTP: ${sanitizeForLog(rtspError?.message || "empty response")}`);
      this.tryReolinkHTTPSnapshot(request, (httpError, httpImage) => {
        if (!httpError && isJPEG(httpImage)) {
          callback(undefined, httpImage);
          return;
        }
        callback(rtspError || httpError || new Error("snapshot unavailable"));
      });
    });
  }

  tryReolinkHTTPSnapshot(request, callback) {
    let rtsp;
    try {
      rtsp = new URL(this.config.rtspUrl);
    } catch (error) {
      callback(error);
      return;
    }
    const params = new URLSearchParams({
      cmd: "Snap",
      channel: "0",
      rs: "HomeLens",
      user: decodeURIComponent(rtsp.username),
      password: decodeURIComponent(rtsp.password),
    });
    const snapshotURL = `http://${rtsp.hostname}/cgi-bin/api.cgi?${params.toString()}`;
    const curl = spawn("/usr/bin/curl", ["-K", "-"], {
      env: process.env,
      stdio: ["pipe", "pipe", "pipe"],
    });
    const chunks = [];
    let stderr = "";
    let settled = false;
    const finish = (error, image) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      callback(error, image);
    };
    const curlConfig = [
      `url = "${snapshotURL.replaceAll("\\", "\\\\").replaceAll("\"", "\\\"")}"`,
      "connect-timeout = 2",
      "max-time = 4",
      "fail",
      "silent",
      "show-error",
      "",
    ].join("\n");
    const timer = setTimeout(() => {
      curl.kill("SIGKILL");
      finish(new Error("HTTP snapshot timed out"));
    }, 5_000);

    curl.stdout.on("data", (data) => chunks.push(data));
    curl.stderr.on("data", (data) => {
      stderr += data.toString("utf8");
    });
    curl.on("error", (error) => finish(error));
    curl.on("exit", (code, signal) => {
      if (code === 0 && chunks.length) {
        finish(undefined, Buffer.concat(chunks));
        return;
      }
      finish(new Error(`curl exited code=${code} signal=${signal} ${stderr.slice(-200)}`));
    });
    curl.stdin.end(curlConfig);
  }

  tryRTSPSnapshot(request, callback) {
    const source = this.streamSourceForResolution(request.width, request.height);
    const args = [
      "-hide_banner",
      "-loglevel",
      "warning",
      "-timeout",
      "6000000",
      "-rtsp_transport",
      "tcp",
      "-i",
      source.url,
      "-frames:v",
      "1",
      "-vf",
      `scale=${request.width}:${request.height}:force_original_aspect_ratio=decrease`,
      "-f",
      "mjpeg",
      "pipe:1",
    ];
    const ffmpeg = spawn(this.config.ffmpegPath, args, { env: process.env });
    const chunks = [];
    let stderr = "";

    const timer = setTimeout(() => {
      ffmpeg.kill("SIGKILL");
    }, 7_000);

    ffmpeg.stdout.on("data", (data) => chunks.push(data));
    ffmpeg.stderr.on("data", (data) => {
      stderr += data.toString("utf8");
    });
    ffmpeg.on("error", (error) => {
      clearTimeout(timer);
      callback(error);
    });
    ffmpeg.on("exit", (code, signal) => {
      clearTimeout(timer);
      if (code === 0 && chunks.length) {
        callback(undefined, Buffer.concat(chunks));
        return;
      }
      callback(new Error(`snapshot ffmpeg exited code=${code} signal=${signal} ${stderr.slice(-300)}`));
    });
  }

  streamSourceForResolution(width, height) {
    // Only use the low-res sub stream when HomeKit asks for something at or below
    // its native size (640×360). For 720p/1080p/4K use the main stream and scale
    // DOWN — sharp — instead of upscaling the tiny sub stream (blurry).
    const useSub = this.config.rtspSubUrl && width <= 640 && height <= 360;
    return {
      name: useSub ? "sub" : "main",
      url: useSub ? this.config.rtspSubUrl : this.config.rtspUrl,
    };
  }

  prepareStream(request, callback) {
    const video = request.video;
    const localVideoPort = nextPort();
    const localVideoRTCPPort = localVideoPort + 1;
    const audio = this.config.audio.enabled ? request.audio : undefined;
    const localAudioPort = audio ? nextPort() : undefined;
    const localAudioRTCPPort = audio ? localAudioPort + 1 : undefined;
    const targetAddress = usableStreamTarget(request);
    const addressOverride = usableLocalStreamAddress(request, targetAddress);
    const videoSSRC = CameraController.generateSynchronisationSource();
    const audioSSRC = CameraController.generateSynchronisationSource();
    log("info", "stream", "prepare stream", {
      sessionID: request.sessionID,
      targetAddress: request.targetAddress,
      remoteAddress: request.remoteAddress,
      selectedTargetAddress: targetAddress,
      sourceAddress: request.sourceAddress,
      addressOverride,
      addressVersion: request.addressVersion,
      videoPort: video.port,
      audioPort: audio?.port,
      localVideoPort,
      localVideoRTCPPort,
      localAudioPort,
      localAudioRTCPPort,
      cryptoSuite: video.srtpCryptoSuite,
    });
    this.pendingSessions.set(request.sessionID, {
      address: targetAddress,
      localAddress: addressOverride,
      videoPort: video.port,
      localVideoPort,
      localVideoRTCPPort,
      videoCryptoSuite: video.srtpCryptoSuite,
      videoSRTP: Buffer.concat([video.srtp_key, video.srtp_salt]),
      videoSSRC,
      audioPort: audio?.port,
      localAudioPort,
      localAudioRTCPPort,
      audioCryptoSuite: audio?.srtpCryptoSuite,
      audioSRTP: audio ? Buffer.concat([audio.srtp_key, audio.srtp_salt]) : undefined,
      audioSSRC: audio ? audioSSRC : undefined,
    });
    const response = {
      addressOverride,
      video: {
        port: localVideoPort,
        ssrc: videoSSRC,
        srtp_key: video.srtp_key,
        srtp_salt: video.srtp_salt,
      },
    };
    if (audio) {
      response.audio = {
        port: localAudioPort,
        ssrc: audioSSRC,
        srtp_key: audio.srtp_key,
        srtp_salt: audio.srtp_salt,
      };
    }
    callback(undefined, response);
  }

  handleStreamRequest(request, callback) {
    switch (request.type) {
      case "start":
        this.startStream(request, callback);
        break;
      case "reconfigure":
        this.reconfigureStream(request, callback);
        break;
      case "stop":
        this.stopStream(request.sessionID, "controller-request");
        callback();
        break;
      default:
        callback(new Error(`Unsupported stream request type ${request.type}`));
    }
  }

  startStream(request, callback) {
    const session = this.pendingSessions.get(request.sessionID);
    if (!session) {
      callback(new Error("Missing prepared session."));
      return;
    }

    this.pendingSessions.delete(request.sessionID);
    session.audio = this.config.audio.enabled ? request.audio : undefined;
    this.launchStreamProcess(request.sessionID, session, request.video, callback, false);
  }

  reconfigureStream(request, callback) {
    const session = this.ongoingSessions.get(request.sessionID);
    if (!session) {
      log("warning", "stream", "HomeKit requested reconfigure for missing session", {
        sessionID: request.sessionID,
        video: request.video,
      });
      callback();
      return;
    }

    const video = { ...session.video, ...request.video };
    if (nativeLiveCopy(this.config, session)) {
      session.video = video;
      log("info", "stream", "keeping original H.264 LAN stream on legacy reconfigure", {
        requested: `${video.width}x${video.height}@${video.fps}`,
        negotiatedBitrateKbps: video.max_bit_rate,
        output: this.config.sourceVideo,
      });
      callback();
      return;
    }
    log("info", "stream", "HomeKit requested stream reconfigure", {
      from: `${session.video.width}x${session.video.height}@${session.video.fps}`,
      to: `${video.width}x${video.height}@${video.fps}`,
      maxBitrate: video.max_bit_rate,
      action: "restart-with-negotiated-settings",
    });
    session.process.kill("SIGKILL");
    this.launchStreamProcess(request.sessionID, session, video, callback, true);
  }

  launchStreamProcess(sessionID, session, video, callback, isReconfigure) {
    const negotiatedProfile = FFMPEG_H264_PROFILES[video.profile] ?? "main";
    const profile = negotiatedProfile;
    const level = ffmpegH264Level(video.width, video.height, FFMPEG_H264_LEVELS[video.level] ?? "4.0");
    const mtu = Math.min(video.mtu || this.config.video.packetSize, this.config.video.packetSize, 1200);
    const bitrate = liveBitrateKbps(video);
    const fps = video.fps || 15;
    const keyframeInterval = Math.max(10, fps);
    const copy = nativeLiveCopy(this.config, session);
    const source = copy ? { name: "main", url: this.config.rtspUrl }
      : this.streamSourceForResolution(video.width, video.height);
    const args = [
      "-hide_banner",
      "-loglevel",
      process.env.HOMELENS_FFMPEG_DEBUG === "1" ? "info" : "warning",
    ];
    if (!copy) args.push("-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld");
    const sourceInfo = source.name === "main" ? this.config.sourceVideo : this.config.sourceSubVideo;
    args.push(
      "-analyzeduration",
      "1000000",
      "-probesize",
      "1000000",
      "-timeout",
      "8000000",
      "-rtsp_transport",
      "tcp",
      ...smoothedTimestampArgs(sourceInfo?.fps),
      "-i",
      source.url,
      "-an",
      "-sn",
      "-dn",
      "-map",
      "0:v:0",
    );

    if (copy) args.push("-c:v", "copy");
    else args.push(
      "-vf",
      hardwareVideoFilter(video.width, video.height, fps, source.name === "main" ? this.config.sourceVideo : undefined),
      "-c:v",
      "h264_videotoolbox",
      "-realtime",
      "1",
      "-b:v",
      `${bitrate}k`,
      "-maxrate",
      `${bitrate}k`,
      "-profile:v", profile,
      "-level:v", level,
      "-coder", profile === "baseline" ? "cavlc" : "cabac",
      "-bf", "0",
      "-r", String(fps),
      "-fps_mode", "cfr",
      "-allow_sw", "0",
      "-g",
      String(keyframeInterval),
      "-force_key_frames",
      `expr:gte(t,n_forced*1)`,
    );

    args.push(
      "-payload_type",
      String(video.pt),
      "-ssrc",
      String(session.videoSSRC),
      "-f",
      "rtp",
    );

    const isSecureRTP = session.videoCryptoSuite !== SRTPCryptoSuites.NONE;
    if (isSecureRTP) {
      const suite = session.videoCryptoSuite === SRTPCryptoSuites.AES_CM_256_HMAC_SHA1_80
        ? "AES_CM_256_HMAC_SHA1_80"
        : "AES_CM_128_HMAC_SHA1_80";
      args.push("-srtp_out_suite", suite, "-srtp_out_params", session.videoSRTP.toString("base64"));
    }

    const protocol = isSecureRTP ? "srtp" : "rtp";
    session.relayVideoPort ??= nextPort();
    const destinationQuery = new URLSearchParams({
      rtcpport: String(session.relayVideoPort + 1),
      pkt_size: String(mtu),
    });
    args.push(`${protocol}://127.0.0.1:${session.relayVideoPort}?${destinationQuery.toString()}`);

    const audio = session.audio;

    log("info", "stream", `${isReconfigure ? "reconfiguring" : "starting"} stream ${video.width}x${video.height}@${video.fps}`, {
      mode: copy ? "copy" : "videotoolbox",
      output: copy ? this.config.sourceVideo : { width: video.width, height: video.height, fps, bitrate },
      source: source.name,
      timestamps: "smoothed",
      negotiatedProfile,
      profile,
      level,
      fps,
      bitrate,
      audio: audio ? `${audio.codec || "unknown"} ${audio.sample_rate || 16}kHz ${audio.channel || 1}ch` : "off",
      rtcpListen: `${session.localAddress}:${session.localVideoPort}`,
      audioRTCPListen: audio ? `${session.localAddress}:${session.localAudioPort}` : undefined,
      target: `${session.address}:${session.videoPort}`,
    });
    log("debug", "ffmpeg", `stream args ${args.map(sanitizeForLog).join(" ")}`);
    let rtcpSocket = session.rtcpSocket;
    if (!rtcpSocket) {
      rtcpSocket = createSocket("udp4");
      session.rtcpPacketCount = 0;
      rtcpSocket.on("error", (error) => {
        log("warning", "stream", `RTCP socket error: ${error.message}`);
      });
      rtcpSocket.on("message", (message, remote) => {
        session.rtcpPacketCount = (session.rtcpPacketCount || 0) + 1;
        if (session.rtcpPacketCount === 1 || session.rtcpPacketCount % 20 === 0) {
          log("debug", "stream", "received RTCP packet", {
            count: session.rtcpPacketCount,
            bytes: message.length,
            remote: `${remote.address}:${remote.port}`,
          });
        }
      });
      rtcpSocket.bind(session.localVideoPort, session.localAddress, () => {
        log("debug", "stream", "RTCP listener ready", {
          local: `${session.localAddress}:${session.localVideoPort}`,
        });
      });
    }
    let audioRtcpSocket = session.audioRtcpSocket;
    if (audio && !audioRtcpSocket) {
      audioRtcpSocket = createSocket("udp4");
      session.audioRtcpPacketCount = 0;
      audioRtcpSocket.on("error", (error) => {
        log("warning", "stream", `Audio RTCP socket error: ${error.message}`);
      });
      audioRtcpSocket.on("message", (message, remote) => {
        session.audioRtcpPacketCount = (session.audioRtcpPacketCount || 0) + 1;
        if (session.audioRtcpPacketCount === 1 || session.audioRtcpPacketCount % 20 === 0) {
          log("debug", "stream", "received audio RTCP packet", {
            count: session.audioRtcpPacketCount,
            bytes: message.length,
            remote: `${remote.address}:${remote.port}`,
          });
        }
      });
      audioRtcpSocket.bind(session.localAudioPort, session.localAddress, () => {
        log("debug", "stream", "Audio RTCP listener ready", {
          local: `${session.localAddress}:${session.localAudioPort}`,
        });
      });
    }
    session.rtcpSocket = rtcpSocket;
    session.audioRtcpSocket = audioRtcpSocket;
    if (!session.videoRelay) {
      session.videoRelay = new PacedRelay({
        name: "video",
        clockRate: 90000,
        send: (packet) => rtcpSocket.send(packet, session.videoPort, session.address),
      });
      session.relaySockets = openRelaySockets(session.videoRelay, session.relayVideoPort);
    }
    const ffmpeg = spawn(this.config.ffmpegPath, args, { env: process.env });
    const audioProcess = audio && !session.audioProcess
      ? this.launchAudioProcess(session, audio)
      : session.audioProcess;
    let callbackSent = false;
    let stderrTail = "";

    const startTimer = setTimeout(() => {
      if (!callbackSent) {
        callbackSent = true;
        callback(new Error("Timed out waiting for ffmpeg to start."));
        this.stopStream(sessionID, "startup-timeout");
      }
    }, 8_000);

    ffmpeg.stderr.on("data", (data) => {
      const text = data.toString("utf8").trim();
      if (text) {
        stderrTail = `${stderrTail}\n${text}`.slice(-4000);
      }
      if (process.env.HOMELENS_FFMPEG_DEBUG === "1" && text) {
        log("debug", "ffmpeg", sanitizeForLog(text));
      }
      if (!callbackSent) {
        callbackSent = true;
        clearTimeout(startTimer);
        callback();
      }
    });
    ffmpeg.on("error", (error) => {
      clearTimeout(startTimer);
      if (!callbackSent) {
        callbackSent = true;
        callback(error);
      }
    });
    ffmpeg.on("exit", (code, signal) => {
      clearTimeout(startTimer);
      const activeSession = this.ongoingSessions.get(sessionID);
      const isActiveProcess = activeSession?.process === ffmpeg;
      if (isActiveProcess) {
        allocatedPorts.delete(session.localVideoPort);
        allocatedPorts.delete(session.localVideoRTCPPort);
        allocatedPorts.delete(session.localAudioPort);
        allocatedPorts.delete(session.localAudioRTCPPort);
        this.closeRelays(activeSession);
        activeSession.rtcpSocket?.close();
        activeSession.audioRtcpSocket?.close();
        activeSession.audioProcess?.kill("SIGKILL");
        this.ongoingSessions.delete(sessionID);
      }
      log(code === 0 || code === 255 || signal ? "info" : "warning", "stream", `ffmpeg exited code=${code} signal=${signal}`);
      if (code && code !== 255 && stderrTail) {
        log("warning", "ffmpeg", `stderr tail ${sanitizeForLog(stderrTail)}`);
      }
      if (!callbackSent) {
        callbackSent = true;
        callback(new Error(`ffmpeg exited before stream started code=${code} signal=${signal}`));
      } else if (isActiveProcess && code && code !== 255) {
        this.controller?.forceStopStreamingSession(sessionID);
      }
    });

    this.ongoingSessions.set(sessionID, {
      ...session,
      process: ffmpeg,
      audioProcess,
      rtcpSocket,
      audioRtcpSocket,
      video,
      audio,
    });

    setImmediate(() => {
      if (!callbackSent) {
        callbackSent = true;
        clearTimeout(startTimer);
        callback();
      }
    });
  }

  launchAudioProcess(session, audio) {
    const audioBitrate = Math.max(audio.max_bit_rate || 24, 24);
    // HomeKit negotiates a sample rate enum in kHz (16 or 24); ffmpeg's -ar wants Hz.
    const negotiatedKHz = Math.max(audio.sample_rate || 16, 16);
    const audioSampleRateHz = negotiatedKHz * 1000;
    const audioChannels = audio.channel || 1;
    // Emit exactly one Opus frame per RTP packet, at the cadence HomeKit negotiated
    // (it asks 20/30/60ms — all valid Opus frame durations). Encoding shorter frames
    // than the controller expects makes its jitter buffer drain unevenly → stutter.
    const validOpusFrameMs = [2.5, 5, 10, 20, 40, 60];
    const requestedFrameMs = audio.packet_time || 20;
    const frameDurationMs = validOpusFrameMs.includes(requestedFrameMs) ? requestedFrameMs : 20;
    const audioProtocol = session.audioCryptoSuite !== SRTPCryptoSuites.NONE ? "srtp" : "rtp";
    session.relayAudioPort ??= nextPort();
    const audioDestinationQuery = new URLSearchParams({
      rtcpport: String(session.relayAudioPort + 1),
      // HomeKit's audio RTP packet size. One Opus frame easily fits in 188 bytes at
      // 24kbps mono; ffmpeg then sends one frame per packet (RFC 7587) instead of
      // bundling several into a 1200-byte burst that overruns iOS's audio buffer.
      pkt_size: "188",
    });
    // Read audio from the lighter sub stream when available (same 16kHz AAC as main,
    // but a 640x360@10 RTSP connection has far less buffering/jitter than re-opening
    // the 4K main solely for its audio track).
    const audioSource = this.config.rtspSubUrl || this.config.rtspUrl;
    const args = [
      "-hide_banner",
      "-loglevel",
      process.env.HOMELENS_FFMPEG_DEBUG === "1" ? "info" : "warning",
      // Keep the camera's own AAC timestamps. -use_wallclock_as_timestamps rewrites
      // every PTS to host arrival time, baking RTSP network jitter into the audio
      // clock; combined with an aggressive resampler that was the stutter source.
      "-fflags",
      "+discardcorrupt",
      "-rtsp_transport",
      "tcp",
      "-i",
      audioSource,
      "-vn",
      "-sn",
      "-dn",
      "-map",
      "0:a:0",
      // Gentle async correction: allow at most ~1 sample of stretch/squeeze per frame
      // to keep the stream continuous without the audible warble of async=1000.
      "-af",
      "aresample=async=1:min_hard_comp=0.100000:first_pts=0",
      "-c:a",
      "libopus",
      // VoIP mode is tuned for low-bitrate mono speech and gives better packet-loss
      // concealment / steadier framing than lowdelay for HomeKit's cadence.
      "-application",
      "voip",
      "-vbr",
      "on",
      "-frame_duration",
      String(frameDurationMs),
      "-ar",
      String(audioSampleRateHz),
      "-b:a",
      `${audioBitrate}k`,
      "-ac",
      String(audioChannels),
      "-payload_type",
      String(audio.pt),
      "-ssrc",
      String(session.audioSSRC),
      "-f",
      "rtp",
    ];
    if (session.audioCryptoSuite !== SRTPCryptoSuites.NONE) {
      const audioSuite = session.audioCryptoSuite === SRTPCryptoSuites.AES_CM_256_HMAC_SHA1_80
        ? "AES_CM_256_HMAC_SHA1_80"
        : "AES_CM_128_HMAC_SHA1_80";
      args.push("-srtp_out_suite", audioSuite, "-srtp_out_params", session.audioSRTP.toString("base64"));
    }
    args.push(`${audioProtocol}://127.0.0.1:${session.relayAudioPort}?${audioDestinationQuery.toString()}`);
    if (!session.audioRelay) {
      session.audioRelay = new PacedRelay({
        name: "audio",
        send: (packet) => session.audioRtcpSocket.send(packet, session.audioPort, session.address),
        delayProvider: () => session.videoRelay?.delayMs ?? 900,
      });
      session.relaySockets.push(...openRelaySockets(session.audioRelay, session.relayAudioPort));
    }

    log("info", "stream", "starting audio stream", {
      audio: `${audio.codec || "unknown"} ${negotiatedKHz}kHz ${audioChannels}ch`,
      source: this.config.rtspSubUrl ? "sub" : "main",
      frameDurationMs,
      packetTimeMs: audio.packet_time,
      target: `${session.address}:${session.audioPort}`,
    });
    log("debug", "ffmpeg", `audio args ${args.map(sanitizeForLog).join(" ")}`);

    const ffmpeg = spawn(this.config.ffmpegPath, args, { env: process.env });
    let stderrTail = "";
    ffmpeg.stderr.on("data", (data) => {
      const text = data.toString("utf8").trim();
      if (text) {
        stderrTail = `${stderrTail}\n${text}`.slice(-4000);
      }
      if (process.env.HOMELENS_FFMPEG_DEBUG === "1" && text) {
        log("debug", "ffmpeg-audio", text);
      }
    });
    ffmpeg.on("exit", (code, signal) => {
      log(code === 0 || code === 255 || signal ? "info" : "warning", "stream", `audio ffmpeg exited code=${code} signal=${signal}`);
      if (code && code !== 255 && stderrTail) {
        log("warning", "ffmpeg-audio", `stderr tail ${sanitizeForLog(stderrTail)}`);
      }
    });
    return ffmpeg;
  }

  closeRelays(session) {
    for (const port of [session.relayVideoPort, session.relayAudioPort]) {
      if (port !== undefined) { allocatedPorts.delete(port); allocatedPorts.delete(port + 1); }
    }
    session.videoRelay?.close();
    session.audioRelay?.close();
    for (const socket of session.relaySockets || []) socket.close();
    session.relaySockets = [];
  }

  stopStream(sessionID, reason = "internal") {
    const session = this.ongoingSessions.get(sessionID);
    if (!session) {
      return;
    }
    log("info", "stream", "stopping stream", {
      sessionID,
      reason,
      rtcpPackets: session.rtcpPacketCount || 0,
      relay: session.videoRelay ? {
        delayMs: session.videoRelay.delayMs, forwarded: session.videoRelay.forwarded, late: session.videoRelay.late,
        audioForwarded: session.audioRelay?.forwarded,
      } : undefined,
    });
    this.closeRelays(session);
    allocatedPorts.delete(session.localVideoPort);
    allocatedPorts.delete(session.localVideoRTCPPort);
    allocatedPorts.delete(session.localAudioPort);
    allocatedPorts.delete(session.localAudioRTCPPort);
    this.ongoingSessions.delete(sessionID);
    session.rtcpSocket?.close();
    session.audioRtcpSocket?.close();
    session.process.kill("SIGKILL");
    session.audioProcess?.kill("SIGKILL");
  }

  updateRecordingActive(active) {
    this.recordingActive = active;
    log("info", "hsv", `recording active ${active}`);
    if (active) {
      this.ensureRecordingPrebuffer();
    } else {
      this.stopRecordingPrebuffer();
    }
  }

  updateRecordingConfiguration(configuration) {
    this.stopRecordingPrebuffer();
    this.recordingConfiguration = configuration;
    if (configuration) {
      const res = configuration.videoCodec?.resolution;
      log("info", "hsv", "recording configuration selected by HomeKit", {
        resolution: res ? `${res[0]}x${res[1]}@${res[2]}` : "?",
        output: recordingPlan(this.config, configuration),
        negotiatedBitrateKbps: configuration.videoCodec?.parameters?.bitRate,
      });
    } else {
      log("info", "hsv", "recording configuration cleared");
    }
    if (configuration && this.recordingActive) {
      this.ensureRecordingPrebuffer();
    }
  }

  async *handleRecordingStreamRequest(streamId, signal) {
    if (!this.recordingConfiguration) {
      throw new Error("HomeKit requested recording without a selected recording configuration.");
    }

    const maxUntil = Date.now() + (this.config.recording.maxSeconds * 1000);

    log("info", "hsv", `starting recording stream ${streamId}`);

    const prebuffer = this.ensureRecordingPrebuffer();
    if (prebuffer && await prebuffer.waitUntilReady(8_000, signal)) {
      yield* prebuffer.generator({
        streamId,
        signal,
        maxUntil,
        isMotionActive: this.isMotionActive,
      });
      return;
    }

    if (signal?.aborted) return;
    // Do not open a second competing RTSP/encoder session when the supervised
    // prebuffer is recovering; fail promptly and let HomeKit retry.
    throw new Error("Recording prebuffer is not ready; retry after camera reconnects.");
  }

  closeRecordingStream(streamId, reason) {
    log("info", "hsv", `close recording stream ${streamId} reason=${reason ?? "unknown"}`);
  }

  acknowledgeStream(streamId) {
    log("info", "hsv", `ack recording stream ${streamId}`);
    this.closeRecordingStream(streamId, "acknowledged");
  }

  ensureRecordingPrebuffer() {
    if (!this.recordingActive || !this.recordingConfiguration) {
      return undefined;
    }
    if (this.prebuffer && (this.prebuffer.destroyed || this.prebuffer.audioActive !== this.isRecordingAudioActive())) {
      this.stopRecordingPrebuffer();
    }
    if (!this.prebuffer) {
      this.prebuffer = new MP4Prebuffer(this.config, this.recordingConfiguration, this.isRecordingAudioActive());
      this.prebuffer.start();
    }
    return this.prebuffer;
  }

  stopRecordingPrebuffer() {
    this.prebuffer?.destroy();
    this.prebuffer = undefined;
  }
}

// Drop surplus frames BEFORE scaling/encoding, while retaining VT surfaces.
// Preserve the source's display aspect ratio for non-16:9 cameras as well.
export function hardwareVideoFilter(width, height, fps, source) {
  const sar = source?.width && source?.height
    ? `${source.width * height}/${source.height * width}` : "1";
  return `fps=${fps},scale_vt=w=${width}:h=${height},setsar=${sar}`;
}

export function recordingPlan(config, recordingConfiguration) {
  const source = config.sourceVideo;
  // iOS/tvOS 27 accepts native H.264/HEVC fMP4 through legacy HDS, including
  // when the legacy selected configuration still says 1080p/H.264. This is an
  // explicit compatibility policy, not a new (invented) HAP codec identifier.
  // See docs/VIDEO_PIPELINE.md for Apple and Scrypted's implementation evidence.
  const copy = config.recording.quality === "native"
    && ["h264", "hevc"].includes(source?.codec);
  const [width, height, fps] = recordingConfiguration.videoCodec.resolution;
  return copy ? { ...source, copy: true }
    : { width, height, fps, codec: "h264", copy: false };
}

export function recordingFFmpegArgs(config, recordingConfiguration, outputURL, audioActive) {
  const plan = recordingPlan(config, recordingConfiguration);
  const video = recordingConfiguration.videoCodec;
  const audio = recordingConfiguration.audioCodec;
  const [width, height, fps] = video.resolution;
  const profile = FFMPEG_H264_PROFILES[video.parameters.profile] ?? "main";
  const level = ffmpegH264Level(width, height, FFMPEG_H264_LEVELS[video.parameters.level] ?? "4.0");
  const bitrate = video.parameters.bitRate || config.video.maxBitrateKbps;
  const fragmentSeconds = Math.max(0.5, recordingConfiguration.mediaContainerConfiguration.fragmentLength / 1000);
  const keyframeSeconds = Math.min(fragmentSeconds, (video.parameters.iFrameInterval || fragmentSeconds * 1000) / 1000);
  const args = [
    "-hide_banner", "-loglevel", process.env.HOMELENS_FFMPEG_DEBUG === "1" ? "info" : "warning",
    "-timeout", "8000000", "-rtsp_transport", "tcp",
    "-analyzeduration", "1000000", "-probesize", "2000000",
  ];
  if (!plan.copy) args.push("-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld");
  args.push(...smoothedTimestampArgs(config.sourceVideo?.fps), "-i", config.rtspUrl, "-map", "0:v:0");
  if (audioActive) args.push("-map", "0:a:0?");
  args.push("-sn", "-dn");
  if (plan.copy) {
    args.push("-c:v", "copy");
    if (plan.codec === "hevc") args.push("-tag:v", "hvc1");
  } else args.push(
    "-vf", hardwareVideoFilter(width, height, fps, config.sourceVideo),
    "-c:v", "h264_videotoolbox", "-allow_sw", "0", "-realtime", "1",
    "-b:v", `${bitrate}k`, "-maxrate", `${bitrate}k`, "-bufsize", `${bitrate * 2}k`,
    "-profile:v", profile, "-level:v", level,
    "-coder", profile === "baseline" ? "cavlc" : "cabac", "-bf", "0",
    "-r", String(fps), "-fps_mode", "cfr",
    "-g", String(Math.max(1, Math.round(keyframeSeconds * fps))),
    "-force_key_frames", `expr:gte(t,n_forced*${keyframeSeconds})`,
  );
  if (audioActive) {
    args.push(
      "-af", "aresample=async=1:min_hard_comp=0.100000:first_pts=0",
      "-c:a", "aac", "-profile:a", audio.type === AudioRecordingCodecType.AAC_ELD ? "aac_eld" : "aac_low",
      "-b:a", `${audio.bitrate || 24}k`, "-ac", String(audio.audioChannels || 1),
      "-ar", String(audioSampleRate(audio.samplerate)),
    );
  } else args.push("-an");
  args.push("-f", "mp4", "-fflags", "+genpts",
    "-movflags", "frag_keyframe+empty_moov+default_base_moof", outputURL);
  return args;
}

function audioSampleRate(sampleRate) {
  switch (sampleRate) {
    case AudioRecordingSamplerate.KHZ_8: return 8000;
    case AudioRecordingSamplerate.KHZ_16: return 16000;
    case AudioRecordingSamplerate.KHZ_24: return 24000;
    case AudioRecordingSamplerate.KHZ_32: return 32000;
    case AudioRecordingSamplerate.KHZ_44_1: return 44100;
    case AudioRecordingSamplerate.KHZ_48:
    default:
      return 48000;
  }
}

function ffmpegH264Level(width, height, negotiatedLevel) {
  // Encoder levels are AVC levels, not HAP enum values.
  if (width * height > 1920 * 1080) return "5.1";
  return negotiatedLevel;
}

export function videoResolutions(config) {
  const source = config.sourceVideo;
  const sizes = [[1920, 1080], [1280, 720]];
  if (config.recording.quality === "native" && source) {
    sizes.unshift([source.width, source.height]);
  }
  const seen = new Set();
  return sizes.filter(([w, h]) => {
    const key = `${w}x${h}`;
    if (seen.has(key) || (source && (w > source.width || h > source.height))) return false;
    seen.add(key); return true;
  }).flatMap(([w, h]) => [[w, h, 30], [w, h, 24], [w, h, 15]]);
}

function h264Levels() {
  return [H264Level.LEVEL3_1, H264Level.LEVEL3_2, H264Level.LEVEL4_0];
}

function liveH264Levels() { return h264Levels(); }

function liveVideoResolutions(config) {
  return [...videoResolutions({ ...config, recording: { quality: "compatible" } }), [640, 360, 15], [320, 240, 15]];
}

export function selfTestRecordingConfiguration(config) {
  return {
    videoCodec: {
      resolution: [1920, 1080, 15],
      parameters: { profile: H264Profile.HIGH, level: H264Level.LEVEL4_0,
        bitRate: 1600, iFrameInterval: 4000 },
    },
    audioCodec: { type: AudioRecordingCodecType.AAC_LC,
      samplerate: AudioRecordingSamplerate.KHZ_48, bitrate: 24, audioChannels: 1 },
    mediaContainerConfiguration: { type: MediaContainerType.FRAGMENTED_MP4,
      fragmentLength: config.recording.fragmentMs },
  };
}

async function runPrebufferSelfTest(config) {
  const timeoutSeconds = Number.parseInt(process.env.HOMELENS_PREBUFFER_SELF_TEST_SECONDS || "20", 10);
  const prebuffer = new MP4Prebuffer(config, selfTestRecordingConfiguration(config), process.env.HOMELENS_PREBUFFER_AUDIO !== "0");
  prebuffer.start();
  try {
    const ready = await prebuffer.waitUntilReady(timeoutSeconds * 1000);
    if (!ready) {
      throw new Error(`prebuffer did not produce a fragment within ${timeoutSeconds}s`);
    }
    const reader = prebuffer.createReader();
    try {
      const fragmentBytes = reader.bufferedFragments.reduce((sum, fragment) => sum + fragment.data.length, 0);
      const payload = {
        ok: true,
        initBytes: reader.initSegment?.length ?? 0,
        fragments: reader.bufferedFragments.length,
        fragmentBytes,
      };
      process.stdout.write(`${JSON.stringify(payload)}\n`);
      log("info", "hsv", "prebuffer self-test passed", payload);
    } finally {
      reader.close();
    }
  } finally {
    prebuffer.destroy();
  }
}

export class MP4Prebuffer {
  constructor(config, recordingConfiguration, audioActive = false) {
    this.config = config;
    this.recordingConfiguration = recordingConfiguration;
    this.audioActive = audioActive;
    this.events = new EventEmitter();
    this.childProcess = undefined;
    this.destroyed = false;
    this.restartTimer = undefined;
    this.restartAttempt = 0;
    this.readBuffer = Buffer.alloc(0);
    this.initBoxes = [];
    this.initSegment = undefined;
    this.currentFragmentBoxes = [];
    this.fragments = [];
    this.nextSequence = 1;
    this.lastDataAt = 0;
    this.watchdogTimer = undefined;
  }

  start() {
    if (this.destroyed || this.childProcess) {
      return;
    }
    this.spawnFFmpeg();
  }

  spawnFFmpeg() {
    if (this.destroyed) {
      return;
    }

    const args = recordingFFmpegArgs(this.config, this.recordingConfiguration, "pipe:1", this.audioActive);
    const recRes = this.recordingConfiguration.videoCodec.resolution;
    log("info", "hsv", `starting recording prebuffer ffmpeg`, {
      resolution: `${recRes[0]}x${recRes[1]}@${recRes[2]}`,
      output: recordingPlan(this.config, this.recordingConfiguration),
      negotiatedBitrateKbps: this.recordingConfiguration.videoCodec.parameters.bitRate,
      source: this.config.sourceVideo,
      audio: this.audioActive ? "on" : "off",
    });
    const child = spawn(this.config.ffmpegPath, args, {
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    this.childProcess = child;
    this.lastDataAt = Date.now();
    this.startWatchdog(child);

    child.stdout.on("data", (data) => {
      this.lastDataAt = Date.now();
      this.handleData(data);
    });
    let stderrTail = "";
    child.stderr.on("data", (data) => {
      stderrTail = (stderrTail + data.toString("utf8")).slice(-2000);
      const text = data.toString("utf8").trim();
      if (process.env.HOMELENS_FFMPEG_DEBUG === "1" && text) {
        log("debug", "ffmpeg-hsv-prebuffer", sanitizeForLog(text));
      }
    });
    child.on("error", (error) => {
      if (!this.destroyed) {
        log("warning", "hsv", `recording prebuffer ffmpeg error: ${error.message}`);
      }
    });
    child.on("exit", (code, signal) => {
      if (this.childProcess === child) {
        this.childProcess = undefined;
      }
      this.stopWatchdog();
      if (this.destroyed) {
        return;
      }
      log(code === 0 || signal ? "info" : "warning", "hsv", `recording prebuffer ffmpeg exited code=${code} signal=${signal}`);
      if (code && stderrTail) log("warning", "hsv", sanitizeForLog(stderrTail));
      this.scheduleRestart();
    });
  }

  startWatchdog(child) {
    this.stopWatchdog();
    const stallTimeoutMs = Math.max(12_000, this.config.recording.stallTimeoutMs || 20_000);
    this.watchdogTimer = setInterval(() => {
      if (this.destroyed || this.childProcess !== child) {
        return;
      }
      const stalledFor = Date.now() - this.lastDataAt;
      if (stalledFor < stallTimeoutMs) {
        return;
      }
      log("warning", "hsv", "recording prebuffer stalled; restarting ffmpeg", {
        stalledForMs: stalledFor,
      });
      child.kill("SIGKILL");
    }, 4_000);
    this.watchdogTimer.unref?.();
  }

  stopWatchdog() {
    clearInterval(this.watchdogTimer);
    this.watchdogTimer = undefined;
  }

  scheduleRestart() {
    if (this.destroyed || this.restartTimer) {
      return;
    }
    // Readers already received the old moov. End them before any new encoder
    // emits a different initialization segment / resets timestamps.
    this.events.emit("closed");
    this.initSegment = undefined;
    this.fragments = [];
    const delay = Math.min(30_000, 1_000 * (2 ** Math.min(this.restartAttempt, 5)));
    this.restartAttempt += 1;
    log("info", "hsv", `recording prebuffer restart in ${delay}ms`);
    this.restartTimer = setTimeout(() => {
      this.restartTimer = undefined;
      this.readBuffer = Buffer.alloc(0);
      this.currentFragmentBoxes = [];
      // Re-arm init capture: the restarted ffmpeg emits a FRESH ftyp+moov whose
      // avcC (SPS/PPS) can differ. Without this, the new init is swallowed into a
      // fragment and HomeKit keeps the stale init → a clip spanning the restart
      // would be undecodable. Drop buffered fragments so we never stitch the old
      // init to new-codec fragments.
      this.initBoxes = [];
      this.initSegment = undefined;
      this.fragments = [];
      this.spawnFFmpeg();
    }, delay);
    this.restartTimer.unref?.();
  }

  handleData(data) {
    this.readBuffer = Buffer.concat([this.readBuffer, data]);
    this.parseAvailableBoxes();
  }

  parseAvailableBoxes() {
    while (this.readBuffer.length >= 8) {
      let size = this.readBuffer.readUInt32BE(0);
      let headerLength = 8;
      if (size === 1) {
        if (this.readBuffer.length < 16) {
          return;
        }
        const extendedSize = this.readBuffer.readBigUInt64BE(8);
        if (extendedSize > BigInt(Number.MAX_SAFE_INTEGER)) {
          log("warning", "hsv", "dropping oversized mp4 box from prebuffer");
          this.destroy();
          return;
        }
        size = Number(extendedSize);
        headerLength = 16;
      }
      if (size < headerLength) {
        log("warning", "hsv", `invalid mp4 box size ${size}`);
        this.destroy();
        return;
      }
      if (this.readBuffer.length < size) {
        return;
      }

      const box = Buffer.from(this.readBuffer.subarray(0, size));
      const type = box.subarray(4, 8).toString("ascii");
      this.readBuffer = this.readBuffer.subarray(size);
      this.handleBox(type, box);
    }
  }

  handleBox(type, box) {
    this.restartAttempt = 0;
    if (!this.initSegment) {
      this.initBoxes.push(box);
      if (type === "moov") {
        this.initSegment = Buffer.concat(this.initBoxes);
        this.initBoxes = [];
        log("info", "hsv", `recording prebuffer init ready bytes=${this.initSegment.length}`);
      }
      return;
    }

    if (type === "moof" && this.currentFragmentBoxes.length) {
      this.flushFragment();
    }
    this.currentFragmentBoxes.push(box);
    if (type === "mdat") {
      this.flushFragment();
    }
  }

  flushFragment() {
    if (!this.currentFragmentBoxes.length) {
      return;
    }
    const fragment = {
      sequence: this.nextSequence,
      createdAt: Date.now(),
      data: Buffer.concat(this.currentFragmentBoxes),
    };
    this.nextSequence += 1;
    this.currentFragmentBoxes = [];
    this.fragments.push(fragment);
    this.prune();
    this.events.emit("fragment", fragment);
    if (this.fragments.length === 1) {
      this.events.emit("ready");
      log("info", "hsv", "recording prebuffer fragments ready");
    }
  }

  prune() {
    const now = Date.now();
    const keepMs = Math.max(
      this.config.recording.prebufferMs,
      this.recordingConfiguration.mediaContainerConfiguration.fragmentLength * 2,
    );
    while (this.fragments.length > 1 && now - this.fragments[0].createdAt > keepMs) {
      this.fragments.shift();
    }

    let totalBytes = this.fragments.reduce((sum, fragment) => sum + fragment.data.length, 0);
    const maxBytes = 64 * 1024 * 1024;
    while (this.fragments.length > 1 && totalBytes > maxBytes) {
      const removed = this.fragments.shift();
      totalBytes -= removed.data.length;
    }
  }

  isReady() {
    return Boolean(this.initSegment && this.fragments.length);
  }

  waitUntilReady(timeoutMs, signal) {
    if (this.isReady()) {
      return Promise.resolve(true);
    }
    if (signal?.aborted) {
      return Promise.resolve(false);
    }

    return new Promise((resolve) => {
      const done = (ready) => {
        clearTimeout(timer);
        this.events.removeListener("ready", onReady);
        signal?.removeEventListener("abort", onAbort);
        resolve(ready);
      };
      const onReady = () => done(true);
      const onAbort = () => done(false);
      const timer = setTimeout(() => done(false), timeoutMs);
      timer.unref?.();
      this.events.once("ready", onReady);
      signal?.addEventListener("abort", onAbort, { once: true });
    });
  }

  createReader() {
    const queue = [];
    let closed = false;
    let resolveWaiter;
    const onFragment = (fragment) => {
      if (closed) return;
      queue.push(fragment);
      if (resolveWaiter) {
        const resolve = resolveWaiter;
        resolveWaiter = undefined;
        resolve();
      }
    };
    // If the prebuffer is destroyed mid-read (reconfigure / shutdown), wake any
    // pending waiter so next() returns undefined immediately instead of hanging
    // until its timeout (which would stall the in-flight recording up to maxUntil).
    const onClosed = () => {
      closed = true;
      queue.length = 0;
      if (resolveWaiter) {
        const resolve = resolveWaiter;
        resolveWaiter = undefined;
        resolve();
      }
    };
    this.events.on("fragment", onFragment);
    this.events.once("closed", onClosed);

    return {
      initSegment: this.initSegment,
      bufferedFragments: [...this.fragments],
      next: (timeoutMs, signal) => {
        if (closed || this.destroyed) return Promise.resolve(undefined);
        if (queue.length) {
          return Promise.resolve(queue.shift());
        }
        if (signal?.aborted || timeoutMs <= 0) {
          return Promise.resolve(undefined);
        }
        return new Promise((resolve) => {
          const done = () => {
            clearTimeout(timer);
            signal?.removeEventListener("abort", onAbort);
            if (resolveWaiter === done) {
              resolveWaiter = undefined;
            }
            resolve(queue.shift());
          };
          const onAbort = () => done();
          const timer = setTimeout(done, timeoutMs);
          timer.unref?.();
          resolveWaiter = done;
          signal?.addEventListener("abort", onAbort, { once: true });
        });
      },
      close: () => {
        closed = true;
        this.events.removeListener("fragment", onFragment);
        this.events.removeListener("closed", onClosed);
        if (resolveWaiter) {
          const resolve = resolveWaiter;
          resolveWaiter = undefined;
          resolve();
        }
      },
    };
  }

  async *generator({ streamId, signal, maxUntil, isMotionActive }) {
    const reader = this.createReader();
    let liveFragments = 0;
    let sentLast = false;
    try {
      log("info", "hsv", `using prebuffer for recording stream ${streamId}`, {
        bufferedFragments: reader.bufferedFragments.length,
      });
      yield { data: reader.initSegment, isLast: false };

      for (const fragment of reader.bufferedFragments) {
        yield { data: fragment.data, isLast: false };
      }

      while (!signal?.aborted) {
        const timeoutMs = Math.max(0, maxUntil - Date.now());
        const fragment = await reader.next(timeoutMs, signal);
        if (!fragment) {
          break;
        }
        liveFragments += 1;
        const timedOut = Date.now() > maxUntil;
        // Require a couple of live fragments before honoring motion-stop so a
        // brief blip doesn't truncate the clip to prebuffer+1.
        const motionStopped = liveFragments >= 2 && !isMotionActive();
        const isLast = Boolean(signal?.aborted || timedOut || motionStopped);
        yield { data: fragment.data, isLast };
        if (isLast) {
          sentLast = true;
          break;
        }
      }

      // HomeKit only finalizes a clip when it receives a packet with isLast=true.
      // If the loop ended because the prebuffer ran dry (ffmpeg restart) or timed
      // out without one — and the controller didn't abort — emit a final marker.
      if (!sentLast && !signal?.aborted) {
        yield { data: Buffer.alloc(0), isLast: true };
      }
      log("info", "hsv", `ending recording stream ${streamId}`);
    } finally {
      reader.close();
    }
  }

  destroy() {
    this.destroyed = true;
    clearTimeout(this.restartTimer);
    this.restartTimer = undefined;
    this.stopWatchdog();
    const child = this.childProcess;
    this.childProcess = undefined;
    if (child && !child.killed) {
      child.kill("SIGTERM");
      const killTimer = setTimeout(() => child.kill("SIGKILL"), 4_000);
      killTimer.unref?.();
    }
    // Wake any in-flight reader so its generator finalizes instead of hanging.
    this.events.emit("closed");
    this.events.removeAllListeners();
  }
}

function createAccessory(config) {
  mkdirSync(config.storagePath, { recursive: true });
  HAPStorage.setCustomStoragePath(config.storagePath);
  const recordingResolutions = videoResolutions(config);
  const recordingLevels = h264Levels(config);
  const supportedResolutions = liveVideoResolutions(config);
  const supportedLevels = liveH264Levels(config);

  const accessoryUUID = uuid.generate(`homelens:${config.host ?? config.rtspUrl}:${config.name}`);
  const accessory = new Accessory(config.name, accessoryUUID);
  accessory.category = Categories.IP_CAMERA;

  accessory
    .getService(Service.AccessoryInformation)
    .setCharacteristic(Characteristic.Manufacturer, "HomeLens")
    .setCharacteristic(Characteristic.Model, "Reolink RTSP/ONVIF Bridge")
    .setCharacteristic(Characteristic.SerialNumber, config.serialNumber || accessoryUUID);

  const delegate = new ReolinkStreamingDelegate(config);
  const controllerOptions = {
    cameraStreamCount: 2,
    delegate,
    streamingOptions: {
      supportedCryptoSuites: [
        SRTPCryptoSuites.AES_CM_128_HMAC_SHA1_80,
        SRTPCryptoSuites.NONE,
      ],
      video: {
        codec: {
          profiles: [H264Profile.BASELINE, H264Profile.MAIN, H264Profile.HIGH],
          levels: supportedLevels,
        },
        resolutions: supportedResolutions,
      },
      audio: {
        twoWayAudio: false,
        comfort_noise: false,
        codecs: [
          {
            type: AudioStreamingCodecType.OPUS,
            audioChannels: 1,
            bitrate: AudioBitrate.VARIABLE,
            samplerate: [AudioStreamingSamplerate.KHZ_16, AudioStreamingSamplerate.KHZ_24],
          },
        ],
      },
    },
    sensors: {
      motion: true,
    },
  };

  if (config.recording.enabled) {
    controllerOptions.recording = {
      options: {
        prebufferLength: config.recording.prebufferMs,
        mediaContainerConfiguration: {
          type: MediaContainerType.FRAGMENTED_MP4,
          fragmentLength: config.recording.fragmentMs,
        },
        video: {
          type: VideoCodecType.H264,
          parameters: {
            profiles: [H264Profile.HIGH, H264Profile.MAIN],
            levels: recordingLevels,
          },
          resolutions: recordingResolutions,
        },
        audio: {
          codecs: {
            type: AudioRecordingCodecType.AAC_LC,
            audioChannels: 1,
            bitrateMode: AudioBitrate.VARIABLE,
            samplerate: [AudioRecordingSamplerate.KHZ_48],
          },
        },
      },
      delegate,
    };
  }

  const controller = new CameraController(controllerOptions);
  delegate.controller = controller;
  accessory.configureController(controller);
  controller.recordingManagement?.recordingManagementService
    .getCharacteristic(Characteristic.RecordingAudioActive).on("change", () => {
      // The management characteristic setter updates recordingAudioActive first.
      setImmediate(() => {
        delegate.stopRecordingPrebuffer();
        delegate.ensureRecordingPrebuffer();
      });
    });
  log("info", "hap", "video capabilities", {
    qualityMode: config.video.qualityMode,
    sources: config.rtspSubUrl ? ["main", "sub"] : ["main"],
    resolutions: supportedResolutions.map((resolution) => `${resolution[0]}x${resolution[1]}@${resolution[2]}`),
    levels: supportedLevels.map((level) => FFMPEG_H264_LEVELS[level] ?? String(level)),
    recordingResolutions: recordingResolutions.map((resolution) => `${resolution[0]}x${resolution[1]}@${resolution[2]}`),
    recordingLevels: recordingLevels.map((level) => FFMPEG_H264_LEVELS[level] ?? String(level)),
  });

  const motionService = controller.motionService ?? accessory.getService(Service.MotionSensor);
  delegate.isMotionActive = () => Boolean(motionService?.getCharacteristic(Characteristic.MotionDetected).value);
  return { accessory, controller, motionService, delegate };
}

async function main() {
  const config = loadConfig();
  config.sourceVideo = await probeVideoSource(config);
  log(config.sourceVideo ? "info" : "warning", "stream", "camera main stream probe", {
    source: config.sourceVideo || "unknown; using conservative HomeKit capabilities",
    recordingQuality: config.recording.quality,
    recordingTransport: "legacy HDS (native 4K/HEVC requires iOS/tvOS 27)",
  });
  config.sourceSubVideo = config.rtspSubUrl
    ? await probeVideoSource({ ...config, rtspUrl: config.rtspSubUrl }) : undefined;
  if (config.sourceSubVideo) log("info", "stream", "camera sub stream probe", { source: config.sourceSubVideo });
  if (config.recording.quality === "native" && !config.sourceVideo) {
    throw new Error("Cannot identify the main stream for native recording; retrying instead of silently reducing quality.");
  }
  if (process.env.HOMELENS_PREBUFFER_SELF_TEST === "1") {
    await runPrebufferSelfTest(config);
    return;
  }

  const { accessory, motionService, delegate } = createAccessory(config);

  const publishInfo = {
    username: config.username,
    pincode: config.pin,
    port: config.port || 51826,
    category: Categories.IP_CAMERA,
  };

  if (config.interfaceName) {
    publishInfo.bind = config.interfaceName;
  }

  await accessory.publish(publishInfo);
  log("info", "hap", `published ${config.name}`, {
    username: config.username,
    pin: config.pin,
    port: publishInfo.port,
  });

  const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
  rl.on("line", (line) => {
    if (!line.trim()) {
      return;
    }
    try {
      const event = JSON.parse(line);
      if (event.type === "motion" || event.type === "person") {
        const active = Boolean(event.active);
        motionService?.updateCharacteristic(Characteristic.MotionDetected, active);
        log("info", "event", `${event.type} ${active ? "active" : "inactive"}`);
      } else if (event.type === "status") {
        log("info", "status", "alive", {
          motion: motionService?.getCharacteristic(Characteristic.MotionDetected).value,
        });
      } else {
        log("warning", "stdin", `unknown event type ${event.type}`);
      }
    } catch (error) {
      log("warning", "stdin", `invalid json line: ${error.message}`);
    }
  });

  const shutdown = async (signal) => {
    log("info", "process", `received ${signal}, shutting down`);
    delegate.stopRecordingPrebuffer();
    for (const sessionID of delegate.ongoingSessions.keys()) delegate.stopStream(sessionID, "shutdown");
    await accessory.unpublish();
    process.exit(0);
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch((error) => {
    log("error", "process", sanitizeForLog(error.stack || error.message));
    process.exitCode = 1;
  });
}
