# Vendored media_kit_video (with iOS PiP)

This package is vendored from
`https://github.com/My-Responsitories/media-kit` (`version_1.2.5` /
`media_kit_video`) and patched to add iOS 15+ Picture-in-Picture.

## Why

PiliPlus cannot push to the upstream media-kit fork used by dependency
overrides. iOS PiP needs `AVSampleBufferDisplayLayer` frame hooks inside
`media_kit_video`, so the package is path-overridden from
`packages/media_kit_video`.

## Patch summary

- Frame callback (`onFrameRendered`) on TextureSW / TextureHW
- `AVPictureInPictureController` + `AVSampleBufferDisplayLayer` pipeline
- Dart API: `VideoController.pictureInPicture` (`PictureInPictureController`)
- Android PiP is intentionally **not** included here — PiliPlus keeps the
  existing JNI `AndroidHelper` path

## Rebase notes

When upgrading the media-kit dependency, re-apply the files under:

- `ios/Classes/plugin/pip/`
- `lib/src/picture_in_picture/`
- Darwin texture / VideoOutput frame-callback changes
