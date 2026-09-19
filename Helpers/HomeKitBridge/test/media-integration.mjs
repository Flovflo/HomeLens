// Opt-in macOS integration test: exercises the installed VideoToolbox pipeline.
// No camera credentials required. Temporary synthetic files are removed on exit.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { recordingFFmpegArgs, selfTestRecordingConfiguration } from "../src/index.mjs";

const ffmpeg = process.env.FFMPEG_PATH || "ffmpeg";
const ffprobe = ffmpeg.replace(/ffmpeg$/, "ffprobe");
const dir = mkdtempSync(join(tmpdir(), "homelens-media-test-"));
function run(binary, args) {
  return execFileSync(binary, args, { encoding: "utf8", timeout: 60_000, maxBuffer: 8 * 1024 * 1024 });
}
const probe = (path) => JSON.parse(run(ffprobe, ["-v", "error", "-show_streams", "-of", "json", path])).streams;
const hashes = (path) => JSON.parse(run(ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_packets",
  "-show_data_hash", "sha256", "-show_entries", "packet=data_hash", "-of", "json", path])).packets.map(p => p.data_hash);

try {
  for (const codec of ["h264", "hevc"]) {
    const source = join(dir, `${codec}-source.mp4`);
    run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=3840x2160:rate=25",
      "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=16000", "-t", "5",
      "-c:v", `${codec === "hevc" ? "hevc" : "h264"}_videotoolbox`, "-allow_sw", "0", "-b:v", "8000k",
      "-g", "50", "-bf", "0", "-c:a", "aac", source]);
    for (const quality of ["native", "compatible"]) {
      const output = join(dir, `${codec}-${quality}.mp4`);
      const config = { rtspUrl: source, video: { maxBitrateKbps: 1600 }, recording: { quality, fragmentMs: 4000 },
        sourceVideo: { codec, width: 3840, height: 2160, fps: 25 } };
      const selected = selfTestRecordingConfiguration(config);
      const args = recordingFFmpegArgs(config, selected, output, true);
      // File fixture replaces only the RTSP input transport, not the encoder/muxer.
      for (const option of ["-timeout", "-rtsp_transport"]) args.splice(args.indexOf(option), 2);
      run(ffmpeg, args);
      const streams = probe(output);
      const video = streams.find(s => s.codec_type === "video");
      const audio = streams.find(s => s.codec_type === "audio");
      assert.equal(video.width, quality === "native" ? 3840 : 1920);
      assert.equal(video.height, quality === "native" ? 2160 : 1080);
      // AAC priming can extend the first fMP4 duration; the coded cadence is r_frame_rate.
      assert.equal(video.r_frame_rate, quality === "native" ? "25/1" : "15/1");
      assert.equal(video.codec_name, quality === "native" ? codec : "h264");
      assert.equal(audio.sample_rate, "48000");
      if (quality === "native") assert.deepEqual(hashes(output), hashes(source), "compressed video must be identical");
      else assert.equal(video.level, 40);
      run(ffmpeg, ["-v", "error", "-xerror", "-i", output, "-f", "null", "-"]);
      console.log(`PASS ${codec} ${quality}: ${video.width}x${video.height} ${video.avg_frame_rate}, AAC ${audio.sample_rate} Hz`);
    }
  }

  // Reolink-style burst: keyframe, +1.6 s timestamp jump, then 49 frames 22 ms apart.
  const clean = join(dir, "h264-source.mp4"), bursty = join(dir, "h264-bursty.mp4"), smoothed = join(dir, "h264-smoothed.mp4");
  run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-i", clean, "-map", "0:v:0", "-c", "copy",
    "-bsf:v", "setts=ts='STARTPTS+(floor(N/50)*2.85+if(eq(mod(N,50),0),0,1.6+(mod(N,50)-1)*0.022))/TB'", bursty]);
  const deltas = (path) => {
    const pts = JSON.parse(run(ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_packets",
      "-show_entries", "packet=pts_time", "-of", "json", path])).packets.map(p => Number(p.pts_time));
    return pts.slice(1).map((t, i) => t - pts[i]);
  };
  assert.ok(Math.max(...deltas(bursty)) > 1.5, "fixture must reproduce the camera's timestamp jump");
  const config = { rtspUrl: bursty, video: { maxBitrateKbps: 1600 }, recording: { quality: "native", fragmentMs: 4000 },
    sourceVideo: { codec: "h264", width: 3840, height: 2160, fps: 25 } };
  const args = recordingFFmpegArgs(config, selfTestRecordingConfiguration(config), smoothed, false);
  for (const option of ["-timeout", "-rtsp_transport"]) args.splice(args.indexOf(option), 2);
  run(ffmpeg, args);
  const out = deltas(smoothed);
  assert.deepEqual(hashes(smoothed), hashes(clean), "re-timing must not touch compressed video");
  assert.ok(Math.min(...out) >= 0.03 && Math.max(...out) <= 0.15, `smoothed cadence ${Math.min(...out)}..${Math.max(...out)}`);
  const total = (d) => d.reduce((n, x) => n + x, 0);
  assert.ok(Math.abs(total(out) - total(deltas(bursty))) < 0.5, "long-term rate must follow the source clock");
  console.log(`PASS bursty timestamps: ${Math.min(...out).toFixed(3)}..${Math.max(...out).toFixed(3)} s between frames, packets identical`);
} finally { rmSync(dir, { recursive: true, force: true }); }
