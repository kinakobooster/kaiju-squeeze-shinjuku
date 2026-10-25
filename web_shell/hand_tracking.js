// Webcam hand tracking for the Godot web build.
// MediaPipe Hand Landmarker runs here in JS; Godot polls window.kaijuHands every frame
// via JavaScriptBridge (21 landmarks per hand, normalized to the *unmirrored* video).
import {
  FilesetResolver,
  HandLandmarker,
} from "https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.14/vision_bundle.mjs";

const WASM = "https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.14/wasm";
const MODEL =
  "https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task";

window.kaijuStatus = "loading";
window.kaijuHands = "";
window.kaijuTogglePreview = () => {
  video.style.display = video.style.display === "none" ? "block" : "none";
};

const video = document.createElement("video");
video.autoplay = true;
video.playsInline = true;
video.muted = true;
video.style.cssText =
  "position:fixed;right:12px;bottom:12px;width:180px;transform:scaleX(-1);opacity:0.6;" +
  "border-radius:8px;z-index:10;pointer-events:none;border:2px solid #9f9;";

async function main() {
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
    window.kaijuStatus = "nocam:unsupported";
    return;
  }
  let stream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({
      video: { width: { ideal: 640 }, height: { ideal: 480 }, facingMode: "user" },
      audio: false,
    });
  } catch (e) {
    window.kaijuStatus = "nocam:" + e.name;
    return;
  }
  video.srcObject = stream;
  document.body.appendChild(video);
  await video.play();

  window.kaijuStatus = "model";
  let landmarker;
  try {
    const fileset = await FilesetResolver.forVisionTasks(WASM);
    const opts = (delegate) => ({
      baseOptions: { modelAssetPath: MODEL, delegate },
      runningMode: "VIDEO",
      numHands: 2,
      minHandDetectionConfidence: 0.5,
      minHandPresenceConfidence: 0.5,
      minTrackingConfidence: 0.5,
    });
    try {
      landmarker = await HandLandmarker.createFromOptions(fileset, opts("GPU"));
    } catch (e) {
      landmarker = await HandLandmarker.createFromOptions(fileset, opts("CPU"));
    }
  } catch (e) {
    window.kaijuStatus = "error:" + (e && e.message ? e.message : e);
    return;
  }
  window.kaijuStatus = "ready";

  let lastTime = -1;
  const loop = () => {
    if (video.readyState >= 2 && video.currentTime !== lastTime) {
      lastTime = video.currentTime;
      const r = landmarker.detectForVideo(video, performance.now());
      const labels = r.handedness || r.handednesses || [];
      const hands = [];
      for (let i = 0; i < r.landmarks.length; i++) {
        const p = [];
        for (const l of r.landmarks[i]) p.push(+l.x.toFixed(4), +l.y.toFixed(4), +l.z.toFixed(4));
        const h = labels[i] && labels[i][0];
        hands.push({ p, label: h ? h.categoryName : "", score: h ? h.score : 0 });
      }
      window.kaijuHands = JSON.stringify({ t: performance.now(), hands });
    }
    requestAnimationFrame(loop);
  };
  loop();
}

main();
