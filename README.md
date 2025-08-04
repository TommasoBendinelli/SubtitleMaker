# VideoSubtitler

**Mac app for automatically transcribing audio and burning subtitles into your videos**

A lightweight macOS utility that scans a folder for video and audio files (MP4, MOV, MKV, AVI, WAV, MP3, etc.), uses OpenAI’s Whisper model to generate SRT subtitle files, and then re-encodes each file—burning the captions directly into the video. Perfect for content creators, educators, and anyone who wants an effortless workflow for subtitling lectures, tutorials, podcasts, and more.

---

## Key Features

- **Batch Processing**  
  Select a folder and process every supported file in one click.
- **Audio & Video Support**  
  Works on both pure-audio (MP3, WAV, M4A, FLAC, AAC, OGG, OPUS) and video formats.
- **Automatic Transcription**  
  Powered by Whisper’s high-accuracy speech-to-text engine, with language auto-detection.
- **Hard-burned Subtitles**  
  Subtitles are permanently embedded into the video, ensuring compatibility across all players.
- **Customizable Quality**  
  Adjustable CRF and ffmpeg presets let you balance file size and visual fidelity.
- **Rescaling**  
  Outputs 720p video by default, with automatic 16:9 black-background canvas for audio-only files.
- **Status Tracking**  
  Real-time progress indicators for each file: Converting → Transcribing → Compressing → Done.

---

## How to Install
Fetch the release from github
## How to Build

**Clone the repository**  
   ```bash
   git clone https://github.com/your-username/VideoSubtitler.git
   cd VideoSubtitler
  ```
**Install dependencies**  
   - **Homebrew** (if not already installed):  
     ```bash
     /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
     ```  
   - **FFmpeg**:  
     ```bash
     brew install ffmpeg
     ```  
   - **Whisper CLI** (optional, for a system‑wide `whisper` binary):  
     ```bash
     brew install whisper
     ```  
   - **Whisper model file**  
     Download `ggml-small.bin` from the official Whisper repository and place it in `VideoSubtitler/Resources/`.

**Open and build**  
   - Launch `VideoSubtitler.xcodeproj` in Xcode.  
   - Select a macOS target (10.15 Catalina or later).  
   - Click **Run** (⌘R) to build and install the app to your Applications folder.  

