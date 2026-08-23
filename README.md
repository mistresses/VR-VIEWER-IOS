# VR Viewer for iOS

A lightweight iOS VR viewer for streaming SteamVR content from a PC to an iPhone.

## Features

- SteamVR screen streaming
- H.264 video decoding
- Live video playback
- Fullscreen streaming
- Hand tracking
- Motion tracking
- PC discovery over the local network
- iOS-native interface

## Requirements

- iPhone running a supported version of iOS
- A Windows PC running the VR Viewer desktop component
- iPhone and PC connected to the same local network
- Compatible VR viewer/headset

## How It Works

VR Viewer receives the video stream from the desktop component over the local network and decodes it on the iPhone.

```text
SteamVR
   │
   ▼
Windows PC
   │
   │ H.264 stream
   ▼
iPhone
   │
   ▼
VR Viewer
