## Summary

<!-- What changes and why. Link the issue, for example "Closes #12". -->

## Validation

- [ ] `xcodebuild test -project OpenLens.xcodeproj -scheme OpenLens -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` passes
- [ ] Tested against a real camera, if the change touches capture, rendering or the extension
- [ ] Tested against real lamps, if the change touches lighting

## Checklist

- [ ] `OpenLens.xcodeproj` regenerated and committed, if `project.yml` changed
- [ ] Tests added or updated for behaviour that changed
- [ ] `README.md` updated, or not affected
- [ ] No change to bundle identifier, layout, architecture, entitlements or minimum macOS version — or the broker profile is being updated to match (see [Releasing](../README.md#releasing))
