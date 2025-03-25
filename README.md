# iOS-VCAM

A powerful iOS tweak that allows you to replace your camera feed with video files in any app that uses the camera.

## Features

- Replace camera feed with video files in real-time
- Works with front and back cameras
- Compatible with all apps that use the standard iOS camera APIs
- Quick toggle with volume buttons (up+down in quick succession)
- Adjustable frame rate for better performance
- Status indicator to show when VCAM is active
- Smooth transitions when enabling/disabling
- Persistent settings between device reboots

## Installation

1. Add the repository to your package manager
2. Install the VCamTeste package
3. Respring your device

## Usage

1. Place a video file at `/tmp/default.mp4`
2. Open any app that uses the camera
3. Press volume up + volume down buttons in quick succession to open the menu
4. Enable VCAM from the menu
5. The video will replace your camera feed

## Future Development

- WebRTC support for streaming from external devices
- Multiple video source support
- Video effect filters
- Custom overlay support
- Preview window

## Technical Details

This tweak hooks into the iOS camera APIs to intercept and replace camera frames with frames from your video file. It supports multiple pixel formats and automatically handles orientation changes.

## Compatibility

- iOS 14.0 and newer
- Works on both jailbroken iPhones and iPads

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Disclaimer

This tweak is meant for educational and entertainment purposes. Always respect others' privacy and follow local laws regarding camera usage.
