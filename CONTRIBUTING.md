# Contributing

Thanks for taking a look at Huge Cursor.

This project is still an interaction prototype, so useful contributions are usually small, focused, and easy to try locally.

## Good First Areas

- Improve shake detection sensitivity.
- Add sample gesture paths for testing.
- Polish the floating input overlay.
- Explore command palette interactions.
- Document macOS permission behavior across sandboxed and non-sandboxed builds.

## Development Notes

Please keep the core idea intact:

- Do not depend on private APIs.
- Do not assume macOS exposes the pointer enlargement state.
- Prefer gesture detection from mouse movement samples.
- Keep the prototype local-first and privacy-conscious.

## Before Opening a Pull Request

Run:

```bash
xcodebuild -project "Huge cursor/Huge cursor.xcodeproj" \
  -scheme "Huge cursor" \
  -configuration Debug \
  -destination "platform=macOS" \
  build
```

Then include a short note about how you tested the gesture behavior.
