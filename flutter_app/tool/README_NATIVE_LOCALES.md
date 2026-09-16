# Native localization additions

`assets/locales/` contains exact copies of the existing Web translations. Do not
edit them for Android-only wording.

- `native_messages.psv` is the editable source for new messages. Each row has the
  English key followed by **20** translated fields, in the language order in the
  first comment. A literal `|` is the field delimiter; avoid it inside a message.
- `native_locale_aliases.json` maps wording variants to semantically equivalent
  original resource paths or another native message. Put native aliases after
  the message they reference. These aliases avoid translating existing wording
  again and keep the source terminology.
- `assets/native_locales/*.json` are generated, committed application assets.
  `AppController` loads the selected original resource and then these additions.

From `flutter_app/`:

```sh
node tool/generate_native_locales.cjs
node tool/generate_native_locales.cjs --check
flutter test test/native_localization_test.dart
```

The check rejects duplicate keys, missing languages, placeholder differences,
changes that would overwrite original top-level messages, stale generated files,
and missing literal `t`/`tr`/validation-exception keys in `lib/`. Dynamic labels
(for example, a key chosen from a list or ternary expression) still need review.

Use `app.errorText(error)` when displaying exceptions. It translates API,
validation, and native authentication errors without changing the exception used
for retry or authorization. Original platform diagnostics and format error
source/position are retained below the translated message; unknown diagnostic
text is intentionally not replaced by a generic error. Branding such as
`ezBookkeeping`, `OpenID Connect`, and the original `Powered by` footer stays
unchanged.
