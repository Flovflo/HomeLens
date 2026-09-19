import assert from "node:assert/strict";
import test from "node:test";
import { MP4Prebuffer, recordingFFmpegArgs, recordingPlan, selfTestRecordingConfiguration, videoResolutions, liveBitrateKbps, nativeLiveCopy, smoothedTimestampArgs } from "../src/index.mjs";

const config = (quality = "native", codec = "h264") => ({
  rtspUrl: "rtsp://camera/main", ffmpegPath: "ffmpeg",
  video: { width: 1920, height: 1080, fps: 15, maxBitrateKbps: 1600 },
  recording: { quality, prebufferMs: 4000, fragmentMs: 4000 },
  sourceVideo: { codec, width: 3840, height: 2160, fps: 25 },
});
const value = (args, key) => args[args.indexOf(key) + 1];

for (const codec of ["h264", "hevc"]) {
  test(`native ${codec}: preserve 4K even with legacy 1080p negotiation`, () => {
    const c = config("native", codec);
    const selected = selfTestRecordingConfiguration(c);
    const args = recordingFFmpegArgs(c, selected, "pipe:1", true);
    assert.equal(value(args, "-c:v"), "copy");
    for (const flag of ["-vf", "-r", "-b:v", "-hwaccel", "-g"]) assert.ok(!args.includes(flag));
    assert.deepEqual(recordingPlan(c, selected), { ...c.sourceVideo, copy: true });
    assert.equal(args.includes("hvc1"), codec === "hevc");
  });
}

test("compatible recording obeys fps, bitrate, profile, level and IDR interval", () => {
  const c = config("compatible", "hevc");
  const selected = selfTestRecordingConfiguration(c);
  selected.videoCodec.parameters.iFrameInterval = 2000;
  const args = recordingFFmpegArgs(c, selected, "pipe:1", false);
  assert.equal(value(args, "-c:v"), "h264_videotoolbox");
  assert.equal(value(args, "-r"), "15");
  assert.equal(value(args, "-g"), "30");
  assert.equal(value(args, "-b:v"), "1600k");
  assert.equal(value(args, "-profile:v"), "high");
  assert.equal(value(args, "-level:v"), "4.0");
  assert.equal(value(args, "-coder"), "cabac");
  assert.ok(value(args, "-vf").startsWith("fps=15,scale_vt=w=1920:h=1080"));
  assert.ok(args.includes("-an"));
  assert.ok(!args.includes("0:a:0?"));
});

test("failed source probe never enables an unsafe native copy", () => {
  const c = config(); delete c.sourceVideo;
  assert.equal(recordingPlan(c, selfTestRecordingConfiguration(c)).copy, false);
  assert.ok(videoResolutions(c).every(([w, h]) => w <= 1920 && h <= 1080));
});

test("recording capabilities include source 4K and HD compatibility, never thumbnails", () => {
  const c = config();
  const modes = videoResolutions(c);
  assert.ok(modes.some(([w, h]) => w === 3840 && h === 2160));
  assert.ok(modes.some(([w, h, fps]) => w === 1920 && h === 1080 && fps === 30));
  assert.ok(modes.every(([w]) => w >= 1280));
  assert.ok(videoResolutions(config("compatible")).every(([w]) => w <= 1920));
});

test("live streaming respects the controller's bandwidth ceiling", () => {
  assert.equal(liveBitrateKbps({ width: 1920, height: 1080, max_bit_rate: 800 }), 800);
});

test("Home 27 original H.264 LAN live avoids low-bitrate recompression; remote/HEVC stay negotiated", () => {
  const lan = { address: "192.168.1.20", localAddress: "192.168.1.10" };
  assert.equal(nativeLiveCopy(config(), lan), true);
  assert.equal(nativeLiveCopy(config("compatible"), lan), false);
  assert.equal(nativeLiveCopy(config("native", "hevc"), lan), false);
  assert.equal(nativeLiveCopy(config(), { ...lan, address: "203.0.113.10" }), false);
  const unknown = config(); delete unknown.sourceVideo;
  assert.equal(nativeLiveCopy(unknown, lan), false);
});

test("prebuffer restart wakes readers and never mixes encoder generations", async () => {
  const c = config();
  const prebuffer = new MP4Prebuffer(c, selfTestRecordingConfiguration(c));
  prebuffer.initSegment = Buffer.from("old-init");
  prebuffer.fragments = [{ sequence: 1, data: Buffer.from("old-media") }];
  const reader = prebuffer.createReader();
  const pending = reader.next(20_000);
  prebuffer.scheduleRestart();
  assert.equal(await pending, undefined);
  assert.equal(prebuffer.isReady(), false);
  prebuffer.events.emit("fragment", { sequence: 2, data: Buffer.from("new-media") });
  assert.equal(await reader.next(20_000), undefined);
  reader.close(); prebuffer.destroy();
});

test("fragmented pipe chunks reconstruct a complete initialization and media fragment", () => {
  const c = config();
  const prebuffer = new MP4Prebuffer(c, selfTestRecordingConfiguration(c));
  const box = (type, text) => {
    const data = Buffer.from(text); const header = Buffer.alloc(8);
    header.writeUInt32BE(data.length + 8); header.write(type, 4);
    return Buffer.concat([header, data]);
  };
  const init = Buffer.concat([box("ftyp", "brand"), box("moov", "codec")]);
  const media = Buffer.concat([box("moof", "metadata"), box("mdat", "video")]);
  const bytes = Buffer.concat([init, media]);
  for (let i = 0; i < bytes.length; i += 3) prebuffer.handleData(bytes.subarray(i, i + 3));
  assert.deepEqual(prebuffer.initSegment, init);
  assert.deepEqual(prebuffer.fragments[0].data, media);
  prebuffer.destroy();
});

test("video timestamps are re-timed before decode or copy, never dropped or re-encoded", () => {
  for (const quality of ["native", "compatible"]) {
    const c = config(quality);
    const args = recordingFFmpegArgs(c, selfTestRecordingConfiguration(c), "pipe:1", false);
    const bsf = args.indexOf("-bsf:v");
    assert.ok(bsf >= 0 && bsf < args.indexOf("-i"), "input-side bitstream filter must precede -i");
    assert.ok(args[bsf + 1].startsWith("setts=ts='") && args[bsf + 1].includes("1/25/TB"));
    assert.ok(!args.includes("-fps_mode") || quality === "compatible");
  }
  const [, unknown] = smoothedTimestampArgs(undefined);
  assert.ok(unknown.includes("1/25/TB") && unknown.includes("NOPTS") && !/\s/.test(unknown));
  assert.ok(smoothedTimestampArgs(10)[1].includes("+19/20*"), "gain follows the nominal rate, clamped");
  assert.ok(unknown.includes("if(gt(isnan(STARTPTS)+eq(STARTPTS,NOPTS),0),0,STARTPTS)"), "origin 0 when the first packet has no timestamp");
});

test("paced relay releases video on its RTP schedule, widens delay on late bursts, keeps audio aligned", async () => {
  const { PacedRelay } = await import("../src/index.mjs");
  let clock = 1_000_000;
  const sent = [];
  const video = new PacedRelay({ name: "video", clockRate: 90000, initialDelayMs: 500, maxDelayMs: 2000,
    now: () => clock, send: (p, rtcp) => sent.push([rtcp ? "rtcp" : "video", p.readUInt32BE(4)]) });
  const audio = new PacedRelay({ name: "audio", now: () => clock, delayProvider: () => video.delayMs,
    send: () => sent.push(["audio"]) });
  const rtp = (ts) => { const b = Buffer.alloc(12); b.writeUInt32BE(ts, 4); return b; };
  // Frame 0 at t=0, frame 1 (ts +40ms) arrives 1.2 s late in a burst.
  assert.equal(video.scheduleTime(rtp(1000), false), 1_000_500);
  clock += 1200;
  const t1 = video.scheduleTime(rtp(1000 + 3600), false);
  assert.equal(t1, clock, "late packet leaves immediately");
  assert.ok(video.delayMs >= 1200 && video.delayMs <= 1400, `delay widened to ${video.delayMs}`);
  assert.equal(video.late, 1);
  // Next frame on time now leaves on schedule with the widened delay.
  const t2 = video.scheduleTime(rtp(1000 + 7200), false);
  assert.equal(t2, 1_000_000 + 80 + video.delayMs);
  assert.equal(audio.scheduleTime(Buffer.alloc(12), false), clock + video.delayMs, "audio follows the video delay");
  assert.equal(video.scheduleTime(Buffer.alloc(12), true), clock + video.delayMs, "RTCP is delayed, not paced");
  // Wrap-around safe.
  const wrap = new PacedRelay({ name: "w", clockRate: 90000, initialDelayMs: 0, now: () => 0, send() {} });
  wrap.scheduleTime(rtp(0xFFFFFF00), false);
  assert.equal(wrap.scheduleTime(rtp(0x00000100), false), (0x200 * 1000) / 90000);
  // Packets of one frame are spread at the pacing rate instead of leaving at once.
  const paced = new PacedRelay({ name: "p", clockRate: 90000, initialDelayMs: 100, paceBytesPerMs: 5000, now: () => 0, send() {} });
  for (let i = 0; i < 100; i += 1) { const b = Buffer.alloc(1200); b.writeUInt32BE(9000, 4); paced.push(b); }
  const targets = paced.queue.map((q) => q.target);
  assert.equal(targets[0], 100);
  assert.ok(Math.abs(targets[99] - (100 + 99 * 1200 / 5000)) < 1e-6, `keyframe spread ${targets[99]}`);
  paced.close();
  // FIFO: a later packet of the same frame never overtakes an earlier one, even when
  // its computed wait is shorter; packets are released in arrival order.
  const order = [];
  const fifo = new PacedRelay({ name: "f", clockRate: 90000, initialDelayMs: 30, send: (p) => order.push(p.readUInt16BE(2)) });
  for (let seq = 0; seq < 40; seq += 1) {
    const b = rtp(5000 + Math.floor(seq / 10) * 3600); b.writeUInt16BE(seq, 2); fifo.push(b);
    await new Promise((r) => setTimeout(r, seq % 3 === 0 ? 2 : 0));
  }
  await new Promise((r) => setTimeout(r, 400));
  assert.deepEqual(order, [...Array(40).keys()], "packets must leave in arrival order");
  fifo.close();
  // Timers are cancelled on close.
  const closed = new PacedRelay({ name: "c", send: () => assert.fail("must not send after close") });
  closed.push(Buffer.alloc(12)); closed.close();
  await new Promise((r) => setTimeout(r, 950));
});
