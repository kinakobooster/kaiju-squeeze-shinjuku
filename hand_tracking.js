// Webcam hand tracking for the Godot web build.
// MediaPipe Hand Landmarker runs here in JS; Godot polls window.kaijuHands every frame
// via JavaScriptBridge (21 landmarks per hand, normalized to the *unmirrored* video).
import {
  FaceLandmarker,
  FilesetResolver,
  HandLandmarker,
} from "https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.14/vision_bundle.mjs";

const WASM = "https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.14/wasm";
const MODEL =
  "https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task";
const FACE_MODEL =
  "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task";

window.kaijuStatus = "loading";
window.kaijuHands = "";
// Face for the items: mouth open (beam), smile (freeze) and nose position (aiming).
window.kaijuFace = "";
window.kaijuTogglePreview = () => {
  video.style.display = video.style.display === "none" ? "block" : "none";
};

const video = document.createElement("video");
video.autoplay = true;
video.playsInline = true;
video.muted = true;
video.style.cssText =
  "position:fixed;right:12px;bottom:12px;width:180px;transform:scaleX(-1);opacity:0.6;" +
  "border-radius:8px;z-index:10;pointer-events:none;border:2px solid #9f9;display:none;";

async function main() {
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
    window.kaijuStatus = "nocam:unsupported";
    return;
  }
  let stream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({
      // a smaller image at a higher frame rate: fast hand moves matter more than detail
      video: {
        width: { ideal: 640 },
        height: { ideal: 360 },
        frameRate: { ideal: 60, min: 30 },
        facingMode: "user",
      },
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

  // The face model is optional: the game works without it, items just won't trigger.
  let face = null;
  FilesetResolver.forVisionTasks(WASM)
    .then((fileset) =>
      FaceLandmarker.createFromOptions(fileset, {
        baseOptions: { modelAssetPath: FACE_MODEL, delegate: "GPU" },
        runningMode: "VIDEO",
        numFaces: 1,
        outputFaceBlendshapes: true,
      })
    )
    .then((f) => (face = f))
    .catch(() => {});

  let frame = 0;
  const detect = () => {
    const now = performance.now();
    const r = landmarker.detectForVideo(video, now);
    const labels = r.handedness || r.handednesses || [];
    const hands = [];
    for (let i = 0; i < r.landmarks.length; i++) {
      const p = [];
      for (const l of r.landmarks[i]) p.push(+l.x.toFixed(4), +l.y.toFixed(4), +l.z.toFixed(4));
      const h = labels[i] && labels[i][0];
      hands.push({ p, label: h ? h.categoryName : "", score: h ? h.score : 0 });
    }
    window.kaijuHands = JSON.stringify({ t: now, hands });
    // faces change slowly; every third frame leaves more time for the hands
    if (face && frame++ % 3 === 0) {
      const fr = face.detectForVideo(video, now);
      if (fr.faceLandmarks.length > 0) {
        const shapes = {};
        for (const c of fr.faceBlendshapes[0].categories) shapes[c.categoryName] = c.score;
        const nose = fr.faceLandmarks[0][1];
        window.kaijuFace = JSON.stringify({
          t: now,
          jaw: +(shapes.jawOpen || 0).toFixed(3),
          smile: +(((shapes.mouthSmileLeft || 0) + (shapes.mouthSmileRight || 0)) / 2).toFixed(3),
          x: +nose.x.toFixed(4),
          y: +nose.y.toFixed(4),
        });
      } else {
        window.kaijuFace = "";
      }
    }
  };
  // run once per new camera frame (not per screen refresh) when the browser can tell us
  if ("requestVideoFrameCallback" in video) {
    const onFrame = () => {
      detect();
      video.requestVideoFrameCallback(onFrame);
    };
    video.requestVideoFrameCallback(onFrame);
  } else {
    let lastTime = -1;
    const loop = () => {
      if (video.readyState >= 2 && video.currentTime !== lastTime) {
        lastTime = video.currentTime;
        detect();
      }
      requestAnimationFrame(loop);
    };
    loop();
  }
}

main();
