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
import { execFileSync, spawn } from "node:child_process";
import { createSocket } from "node:dgram";
import { EventEmitter, once } from "node:events";
import { createServer } from "node:net";
import { createInterface } from "node:readline";
import { mkdirSync, readFileSync } from "node:fs";
import { networkInterfaces } from "node:os";
import { dirname, resolve } from "node:path";

const DEFAULT_PIN = "031-45-154";
const DEFAULT_USERNAME = "A2:44:5A:11:00:06";
const FFMPEG_H264_PROFILES = ["baseline", "main", "high"];
const H264_LEVEL_5_0 = 3;
const H264_LEVEL_5_1 = 4;
const FFMPEG_H264_LEVELS = ["3.1", "3.2", "4.0", "5.0", "5.1"];

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

// Detect the camera's main-stream video codec ("h264" / "hevc") so we know
// whether we can pass it through to HomeKit untouched (H.264) or must transcode
// (H.265 → H.264, since HomeKit only accepts H.264).
function probeVideoCodec(config) {
  const ffprobe = config.ffmpegPath.replace(/ffmpeg(\b|$)/, "ffprobe");
  try {
    const out = execFileSync(ffprobe, [
      "-v", "error", "-rtsp_transport", "tcp", "-timeout", "6000000",
      "-i", config.rtspUrl, "-select_streams", "v:0",
      "-show_entries", "stream=codec_name", "-of", "default=nokey=1:noprint_wrappers=1",
    ], { encoding: "utf8", timeout: 12_000, stdio: ["ignore", "pipe", "ignore"] });
    const codec = (out || "").trim().toLowerCase();
    return codec || "h264";
  } catch {
    return "h264"; // assume H.264 (copy path) if the probe fails
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
  config.recording.enabled = config.recording.enabled !== false;
  config.recording.prebufferMs ||= 4000;
  config.recording.fragmentMs ||= 4000;
  config.recording.maxSeconds ||= 20;
  config.recording.stallTimeoutMs ||= 20_000;
  return config;
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

function liveBitrateKbps(video) {
  const negotiated = video.max_bit_rate || 0;
  const pixels = (video.width || 0) * (video.height || 0);
  let target = 800;
  if (pixels >= 3840 * 2160) {
    target = 12000;
  } else if (pixels >= 2560 * 1440) {
    target = 6000;
  } else if (pixels >= 1920 * 1080) {
    target = 4000;
  } else if (pixels >= 1280 * 720) {
    target = 2500;
  } else if (pixels >= 640 * 360) {
    target = 1000;
  }
  // Bias toward sharpness on a good LAN: give at least our target, and honor a
  // higher value if HomeKit asks for more. (HomeKit often negotiates a very low
  // ceiling, which on its own yields a soft image.)
  return Math.max(negotiated, target);
}

class ReolinkStreamingDelegate {
  constructor(config) {
    this.config = config;
    this.pendingSessions = new Map();
    this.ongoingSessions = new Map();
    this.recordingActive = false;
    this.recordingConfiguration = undefined;
    this.recordingServer = undefined;
    this.prebuffer = undefined;
    this.controller = undefined;
    this.isMotionActive = () => false;
  }

  // Whether HomeKit Secure Video should capture the camera's audio. HomeKit's
  // RecordingAudioActive characteristic defaults to 0 (off) until the user flips
  // "record audio" in the Home app, which would leave clips silent. Since audio
  // is an explicit product goal, drive it from the HomeLens config instead
  // (on by default; set audio.enabled=false to opt out).
  isRecordingAudioActive() {
    return this.config.audio.enabled !== false;
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
    log("info", "stream", "HomeKit requested stream reconfigure", {
      from: `${session.video.width}x${session.video.height}@${session.video.fps}`,
      to: `${video.width}x${video.height}@${video.fps}`,
      maxBitrate: video.max_bit_rate,
      action: "kept-current-stream",
    });
    callback();
  }

  launchStreamProcess(sessionID, session, video, callback, isReconfigure) {
    const negotiatedProfile = FFMPEG_H264_PROFILES[video.profile] ?? "main";
    const profile = negotiatedProfile === "high" ? "main" : negotiatedProfile;
    const level = ffmpegH264Level(video.width, video.height, FFMPEG_H264_LEVELS[video.level] ?? "4.0");
    const mtu = Math.min(video.mtu || this.config.video.packetSize, this.config.video.packetSize, 1200);
    const bitrate = liveBitrateKbps(video);
    const fps = Math.min(video.fps || this.config.video.fps, this.config.video.fps || 15);
    const keyframeInterval = Math.max(10, fps);
    const source = this.streamSourceForResolution(video.width, video.height);
    const canDirectCopy = this.config.video.directCopy &&
      this.config.sourceVideoCodec === "h264" &&
      source.name === "main" &&
      Math.abs(video.width - this.config.video.width) <= 16 &&
      Math.abs(video.height - this.config.video.height) <= 16;
    const args = [
      "-hide_banner",
      "-loglevel",
      process.env.HOMELENS_FFMPEG_DEBUG === "1" ? "info" : "warning",
    ];
    if (!canDirectCopy) {
      // Decode on the Apple Silicon media engine so the whole transcode pipeline
      // (decode → scale_vt → h264_videotoolbox encode) stays in hardware (~10% CPU,
      // sharp downscale from the 4K main stream).
      args.push("-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld");
    }
    args.push(
      "-fflags",
      "nobuffer",
      "-flags",
      "low_delay",
      "-analyzeduration",
      "1000000",
      "-probesize",
      "1000000",
      "-timeout",
      "8000000",
      "-rtsp_transport",
      "tcp",
      "-i",
      source.url,
      "-an",
      "-sn",
      "-dn",
      "-map",
      "0:v:0",
    );

    if (canDirectCopy) {
      args.push(
        "-c:v",
        "copy",
        "-bsf:v",
        "h264_mp4toannexb",
      );
    } else {
      // Hardware scale + encode on the Apple media engine (frames stay as
      // VideoToolbox surfaces end-to-end). scale_vt keeps the 4K main stream's
      // aspect (camera and all HomeKit sizes are 16:9, so no padding needed).
      args.push(
        "-vf",
        `scale_vt=w=${video.width}:h=${video.height}`,
        "-c:v",
        "h264_videotoolbox",
        "-realtime",
        "1",
        "-b:v",
        `${bitrate}k`,
        "-maxrate",
        `${bitrate}k`,
        "-profile:v",
        profile,
        "-g",
        String(keyframeInterval),
        "-force_key_frames",
        `expr:gte(t,n_forced*1)`,
      );
    }

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
    const destinationQuery = new URLSearchParams({
      rtcpport: String(session.videoPort),
      pkt_size: String(mtu),
    });
    args.push(`${protocol}://${session.address}:${session.videoPort}?${destinationQuery.toString()}`);

    const audio = session.audio;

    log("info", "stream", `${isReconfigure ? "reconfiguring" : "starting"} stream ${video.width}x${video.height}@${video.fps}`, {
      mode: canDirectCopy ? "copy" : "transcode",
      source: source.name,
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
        log("debug", "ffmpeg", text);
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
    const audioDestinationQuery = new URLSearchParams({
      rtcpport: String(session.audioPort),
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
    args.push(`${audioProtocol}://${session.address}:${session.audioPort}?${audioDestinationQuery.toString()}`);

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

  stopStream(sessionID, reason = "internal") {
    const session = this.ongoingSessions.get(sessionID);
    if (!session) {
      return;
    }
    log("info", "stream", "stopping stream", {
      sessionID,
      reason,
      rtcpPackets: session.rtcpPacketCount || 0,
    });
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
      const isNative4K = res && res[0] === this.config.video.width && res[1] === this.config.video.height;
      log("info", "hsv", "recording configuration selected by HomeKit", {
        resolution: res ? `${res[0]}x${res[1]}@${res[2]}` : "?",
        is4K: Boolean(res && res[0] >= 3840),
        usesNativeResolution: Boolean(isNative4K),
        bitrateKbps: configuration.videoCodec?.parameters?.bitRate,
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

    const server = new MP4FragmentServer(this.config, this.recordingConfiguration, this.isRecordingAudioActive());
    this.recordingServer = server;
    let yieldedFragments = 0;
    let pending = [];
    signal?.addEventListener("abort", () => server.destroy(), { once: true });
    log("warning", "hsv", `prebuffer not ready, using on-demand recording stream ${streamId}`);
    try {
      await server.start();
      for await (const box of server.generator()) {
        pending.push(box.header, box.data);
        if (box.type !== "moov" && box.type !== "mdat") {
          continue;
        }

        yieldedFragments += box.type === "mdat" ? 1 : 0;
        const timedOut = Date.now() > maxUntil;
        const motionStopped = yieldedFragments > 1 && !this.isMotionActive();
        const isLast = Boolean(signal?.aborted || timedOut || motionStopped);
        yield {
          data: Buffer.concat(pending),
          isLast,
        };
        pending = [];
        if (isLast) {
          log("info", "hsv", `ending recording stream ${streamId}`);
          break;
        }
      }
    } finally {
      server.destroy();
      if (this.recordingServer === server) {
        this.recordingServer = undefined;
      }
    }
  }

  closeRecordingStream(streamId, reason) {
    log("info", "hsv", `close recording stream ${streamId} reason=${reason ?? "unknown"}`);
    this.recordingServer?.destroy();
    this.recordingServer = undefined;
  }

  acknowledgeStream(streamId) {
    log("info", "hsv", `ack recording stream ${streamId}`);
    this.closeRecordingStream(streamId, "acknowledged");
  }

  ensureRecordingPrebuffer() {
    if (!this.recordingActive || !this.recordingConfiguration) {
      return undefined;
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

function recordingFFmpegArgs(config, recordingConfiguration, outputURL, audioActive) {
  const video = recordingConfiguration.videoCodec;
  const audio = recordingConfiguration.audioCodec;
  const width = video.resolution[0];
  const height = video.resolution[1];
  const fps = video.resolution[2];
  const profile = FFMPEG_H264_PROFILES[video.parameters.profile] ?? "main";
  const level = ffmpegH264Level(width, height, FFMPEG_H264_LEVELS[video.parameters.level] ?? "4.0");
  const bitrate = video.parameters.bitRate || config.video.maxBitrateKbps;
  const fragmentSeconds = Math.max(1, recordingConfiguration.mediaContainerConfiguration.fragmentLength / 1000);

  // HomeKit always wants H.264. Copy the camera's stream untouched only when it
  // is ALREADY H.264 AND the recording size matches the camera's native size.
  // An H.265/HEVC camera (or a smaller negotiated size) must be transcoded to
  // H.264 — done entirely on the Apple media engine (HW decode + HW encode).
  const canCopyVideo = width === config.video.width
    && height === config.video.height
    && config.sourceVideoCodec === "h264";

  const args = [
    "-hide_banner",
    "-loglevel",
    process.env.HOMELENS_FFMPEG_DEBUG === "1" ? "info" : "warning",
    "-timeout",
    "8000000",
    "-rtsp_transport",
    "tcp",
  ];
  if (!canCopyVideo) {
    // Hardware-decode the source (handles H.265 too) so the transcode stays on
    // the media engine instead of doing software HEVC decode of a 4K stream.
    args.push("-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld");
  }
  args.push("-i", config.rtspUrl, "-map", "0:v:0");

  // Record the camera's real audio when HomeKit keeps "record audio" enabled.
  // The trailing "?" makes the audio map optional so a camera without an audio
  // track never aborts the recording.
  if (audioActive) {
    args.push("-map", "0:a:0?");
  }

  args.push("-sn", "-dn");

  if (canCopyVideo) {
    // Native H.264 at native size → pass the original stream through untouched
    // (true 4K, near-zero CPU for the always-on prebuffer).
    args.push("-c:v", "copy");
  } else {
    if (width !== config.video.width || height !== config.video.height) {
      args.push("-vf", `scale_vt=w=${width}:h=${height}`);
    }
    args.push(
      "-c:v",
      "h264_videotoolbox",
      "-realtime",
      "1",
      "-b:v",
      `${bitrate}k`,
      "-maxrate",
      `${bitrate}k`,
      "-profile:v",
      profile,
      // Set the GOP ceiling just above the source GOP and force a keyframe at each
      // fragment boundary, so every HKSV fragment is ~fragmentLength and starts
      // with an IDR. (force_key_frames does the alignment; -g keeps VideoToolbox's
      // short default GOP from spraying extra keyframes → tiny fragments + wasted
      // bitrate.) Verified: clean 4s IDR-led fragments.
      "-g",
      String(Math.round(fragmentSeconds * 30)),
      "-force_key_frames",
      `expr:gte(t,n_forced*${fragmentSeconds})`,
    );
  }

  if (audioActive) {
    // HKSV requires 32/48kHz AAC-LC/ELD; the Reolink source is 16kHz AAC-LC, so
    // ffmpeg resamples to the negotiated rate. Match the live path's gentle
    // resampler (soft compensation) to keep A/V in sync without warble.
    args.push(
      "-af",
      "aresample=async=1:min_hard_comp=0.100000:first_pts=0",
      "-c:a",
      "aac",
      "-profile:a",
      audio.type === AudioRecordingCodecType.AAC_ELD ? "aac_eld" : "aac_low",
      "-b:a",
      `${audio.bitrate || 24}k`,
      "-ac",
      String(audio.audioChannels || 1),
      "-ar",
      String(audioSampleRate(audio.samplerate)),
    );
  } else {
    args.push("-an");
  }

  args.push(
    "-f",
    "mp4",
    "-fflags",
    "+genpts",
    "-movflags",
    "frag_keyframe+empty_moov+default_base_moof",
    outputURL,
  );

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
  const pixels = width * height;
  if (pixels >= 3840 * 2160) {
    return "5.1";
  }
  if (pixels >= 2560 * 1440) {
    return "5.0";
  }
  return negotiatedLevel;
}

function videoResolutions(config) {
  const fps = config.video.fps || 15;
  let candidates;
  switch (config.video.qualityMode) {
    case "high":
      candidates = [
        [config.video.width, config.video.height, fps],
        [3840, 2160, fps],
        [2560, 1440, fps],
        [1920, 1080, fps],
      ];
      break;
    case "balanced":
      candidates = [
        [1920, 1080, fps],
        [1280, 720, fps],
        [640, 360, fps],
        [320, 180, fps],
      ];
      break;
    case "adaptive":
    default:
      candidates = [
        [config.video.width, config.video.height, fps],
        [3840, 2160, fps],
        [2560, 1440, fps],
        [1920, 1080, fps],
        [1280, 720, fps],
        [640, 360, fps],
        [320, 180, fps],
      ];
      break;
  }
  const seen = new Set();
  return candidates
    .filter(([width, height]) => width <= config.video.width && height <= config.video.height)
    .filter((resolution) => {
      const key = resolution.join("x");
      if (seen.has(key)) {
        return false;
      }
      seen.add(key);
      return true;
    });
}

function h264Levels(config) {
  const levels = [H264Level.LEVEL3_1, H264Level.LEVEL3_2, H264Level.LEVEL4_0];
  if ((config.video.width * config.video.height) >= 2560 * 1440) {
    levels.push(H264_LEVEL_5_0);
  }
  if ((config.video.width * config.video.height) >= 3840 * 2160) {
    levels.push(H264_LEVEL_5_1);
  }
  return levels;
}

function liveH264Levels(config) {
  return h264Levels(config);
}

function liveVideoResolutions(config) {
  const fps = config.video.fps || 15;
  const candidates = [
    [config.video.width, config.video.height, fps],
    [3840, 2160, fps],
    [2560, 1440, fps],
    [1920, 1080, fps],
    [1280, 720, fps],
    [640, 360, fps],
    [320, 180, fps],
  ];
  const seen = new Set();
  return candidates
    .filter(([width, height]) => width <= config.video.width && height <= config.video.height)
    .filter((resolution) => {
      const key = resolution.join("x");
      if (seen.has(key)) {
        return false;
      }
      seen.add(key);
      return true;
    });
}

function selfTestRecordingConfiguration(config) {
  return {
    videoCodec: {
      resolution: [config.video.width, config.video.height, config.video.fps],
      parameters: {
        profile: H264Profile.HIGH,
        level: h264LevelForPixels(config.video.width, config.video.height),
        bitRate: config.video.maxBitrateKbps,
      },
    },
    audioCodec: {
      type: AudioRecordingCodecType.AAC_LC,
      samplerate: AudioRecordingSamplerate.KHZ_48,
      bitrate: 24,
      audioChannels: 1,
    },
    mediaContainerConfiguration: {
      type: MediaContainerType.FRAGMENTED_MP4,
      fragmentLength: config.recording.fragmentMs,
    },
  };
}

function h264LevelForPixels(width, height) {
  const pixels = width * height;
  if (pixels >= 3840 * 2160) {
    return H264_LEVEL_5_1;
  }
  if (pixels >= 2560 * 1440) {
    return H264_LEVEL_5_0;
  }
  return H264Level.LEVEL4_0;
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

class MP4Prebuffer {
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
    const recNative = recRes[0] === this.config.video.width
      && recRes[1] === this.config.video.height
      && this.config.sourceVideoCodec === "h264";
    log("info", "hsv", `starting recording prebuffer ffmpeg`, {
      resolution: `${recRes[0]}x${recRes[1]}@${recRes[2]}`,
      mode: recNative ? "copy (native, full quality)" : "transcode/scale",
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
    child.stderr.on("data", (data) => {
      const text = data.toString("utf8").trim();
      if (process.env.HOMELENS_FFMPEG_DEBUG === "1" && text) {
        log("debug", "ffmpeg-hsv-prebuffer", text);
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
    let resolveWaiter;
    const onFragment = (fragment) => {
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

class MP4FragmentServer {
  constructor(config, recordingConfiguration, audioActive = false) {
    this.config = config;
    this.recordingConfiguration = recordingConfiguration;
    this.audioActive = audioActive;
    this.server = createServer(this.handleConnection.bind(this));
    this.socket = undefined;
    this.childProcess = undefined;
    this.destroyed = false;
    this.connected = new Promise((resolve) => {
      this.resolveConnected = resolve;
    });
  }

  async start() {
    this.server.listen(0, "127.0.0.1");
    await once(this.server, "listening");
    if (this.destroyed) {
      return;
    }

    const port = this.server.address().port;
    const args = this.ffmpegArgs(`tcp://127.0.0.1:${port}`);
    log("info", "hsv", "starting recording ffmpeg");
    this.childProcess = spawn(this.config.ffmpegPath, args, {
      env: process.env,
      stdio: process.env.HOMELENS_FFMPEG_DEBUG === "1" ? ["ignore", "ignore", "pipe"] : "ignore",
    });
    this.childProcess?.stderr?.on("data", (data) => log("debug", "ffmpeg-hsv", data.toString("utf8").trim()));
    this.childProcess?.on("exit", (code, signal) => {
      if (!this.destroyed) {
        log(code === 0 || signal ? "info" : "warning", "hsv", `recording ffmpeg exited code=${code} signal=${signal}`);
      }
    });
  }

  ffmpegArgs(outputURL) {
    return recordingFFmpegArgs(this.config, this.recordingConfiguration, outputURL, this.audioActive);
  }

  handleConnection(socket) {
    this.server.close();
    this.socket = socket;
    this.resolveConnected();
  }

  async *generator() {
    await this.connected;
    while (!this.destroyed) {
      const header = await this.read(8);
      const length = header.readUInt32BE(0) - 8;
      const type = header.subarray(4).toString("ascii");
      const data = await this.read(length);
      yield { header, length, type, data };
    }
  }

  async read(length) {
    if (!this.socket) {
      throw new Error("recording socket is closed");
    }
    if (length === 0) {
      return Buffer.alloc(0);
    }

    const available = this.socket.read(length);
    if (available) {
      return available;
    }

    return new Promise((resolve, reject) => {
      const readable = () => {
        const value = this.socket?.read(length);
        if (value) {
          cleanup();
          resolve(value);
        }
      };
      const closed = () => {
        cleanup();
        reject(new Error("recording socket closed"));
      };
      const cleanup = () => {
        this.socket?.removeListener("readable", readable);
        this.socket?.removeListener("close", closed);
        this.socket?.removeListener("end", closed);
      };
      this.socket.on("readable", readable);
      this.socket.on("close", closed);
      this.socket.on("end", closed);
    });
  }

  destroy() {
    this.destroyed = true;
    this.socket?.destroy();
    this.server.close();
    this.childProcess?.kill("SIGTERM");
    this.socket = undefined;
    this.childProcess = undefined;
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
            profiles: [H264Profile.MAIN, H264Profile.HIGH],
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
  return { accessory, controller, motionService };
}

async function main() {
  const config = loadConfig();
  config.sourceVideoCodec = probeVideoCodec(config);
  log("info", "stream", `camera main video codec: ${config.sourceVideoCodec}`, {
    mode: config.sourceVideoCodec === "h264" ? "copy-capable (H.264)" : "transcode-to-H.264 (HomeKit needs H.264)",
  });
  if (process.env.HOMELENS_PREBUFFER_SELF_TEST === "1") {
    await runPrebufferSelfTest(config);
    return;
  }

  const { accessory, motionService } = createAccessory(config);

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
    await accessory.unpublish();
    process.exit(0);
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
}

main().catch((error) => {
  log("error", "process", error.stack || error.message);
  process.exit(1);
});
