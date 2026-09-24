# Prompt reset and instruction-boundary review

Reviewed the final prompt composition, stored settings, draft editor and recording snapshot behavior. No additional defect was found in these paths. This is source review supported by isolated-default regression tests and the synthetic provider cases; it is not a new native UI click test.

- A saved Full override loads unchanged and replaces the built-in style text. Updating the public default does not overwrite that saved choice.
- Editing and **Reset to default** change only the draft. **Cancel** discards the draft. An empty draft cannot replace a saved prompt.
- **Reset to default → Save** stores an empty override, so this installation uses the current built-in prompt and can follow later default updates. It does not save a frozen copy of today's default text.
- Legacy additional style preferences, dictionary entries and languages remain intact. The additional style preferences can still affect output after resetting the main Full style text; reset does not erase separate settings.
- A recording snapshots its Full override at its start. A newly saved prompt affects the next recording, matching the editor's instruction to save before dictating.
- Light uses its own public contract. Changing the Full style does not silently replace Light's instructions.

The fixed prompt composition keeps the content/instruction boundary and literal, language, numeric and email safeguards active even with a custom Full style. The text-completion request has no tool-execution interface, and no selected-text command mode was added from the supplied reference. English and Chinese synthetic requests to ignore rules or generate other content were returned as cleaned dictation in both modes. These tests support the intended behavior; they do not establish that every possible model response or user-written custom prompt is safe or faithful.

Relevant implementation: [draft persistence](https://github.com/shengha2/expertise-dictation/blob/v1.1.11/Sources/FnDictate/Settings.swift), [editor actions](https://github.com/shengha2/expertise-dictation/blob/v1.1.11/Sources/FnDictate/SettingsView.swift), [composed prompt](https://github.com/shengha2/expertise-dictation/blob/v1.1.11/Sources/FnDictate/CleanupPrompt.swift), [recording snapshot](https://github.com/shengha2/expertise-dictation/blob/v1.1.11/Sources/FnDictate/DictationController.swift), and [isolated regression checks](https://github.com/shengha2/expertise-dictation/blob/v1.1.11/Sources/FnDictate/PromptModelRegressionTests.swift).
