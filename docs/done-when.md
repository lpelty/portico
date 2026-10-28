# Done-when checks, v0.1.0

The nine checks from the design's "Done when" list. A box is ticked only
when an automated test or probe in this repo demonstrably covers it, and
the test is cited. The rest are marked **manual** for a person at the
screen; where a check cannot run without a provider credential, it says so.

Baseline on 2026-10-28, before this closing commit:

- `cd gateway && uv run pytest -q`: 163 passed, 1 skipped (the opt-in live smoke)
- `cd app && swift test`: 77 tests, 1 skipped (the opt-in live hello handshake), 0 failures
- `tests/test_distribution.py`: 2 passed

Opt-in live tests, when a credential is in the environment:

- `cd gateway && PORTICO_LIVE=1 uv run pytest tests/test_live_smoke.py -v`
- `cd app && PORTICO_GATEWAY_URL=ws://127.0.0.1:<port> PORTICO_GATEWAY_TOKEN=<token> swift test --filter testLiveHelloHandshake`

## The checks

### 1. Fresh clone: one command starts the gateway; `swift run` opens the app; pick a folder; send a message; the reply streams.

- [ ] **manual — Larry.** Needs a credential in the environment and a window.
  - Automated pieces: the gateway's ready line and ledger
    (`gateway/tests/test_server.py::test_ready_line_and_ledger`), the app
    starting a gateway from its command and reading the ready line and token
    (`app/Tests/PorticoTests/GatewayClientTests.swift::testStartReadsReadyLineAndToken`),
    folder validation on `chat.new`
    (`gateway/tests/test_turns.py::test_new_chat_starts_engine_in_folder_with_project_setting_sources`),
    streamed text with sequence numbers
    (`gateway/tests/test_turns.py::test_send_streams_text_and_tool_events_with_seq`)
    and text deltas coalescing in the app
    (`app/Tests/PorticoTests/AppModelTests.swift::testApplyTextDeltasCoalesce`).
  - Not automated: a fresh clone through `bin/install`, the real window,
    the reply from a real model.

### 2. Ask for a file write: a permission card appears; deny leaves no file and the agent says it was denied; allow writes it, and the file opens in the viewer on its own.

- [ ] **manual — Larry.** Needs a credential in the environment.
  - Automated pieces: the permission round trip on allow
    (`gateway/tests/test_cards.py::test_permission_card_round_trip_allow_once`),
    deny carrying a note to the engine
    (`gateway/tests/test_engine_translate.py::test_deny_carries_note`), a
    denied or failed write leaving no artifact
    (`gateway/tests/test_artifacts.py::test_denied_or_failed_write_leaves_no_artifact`),
    a written file collected and opened at the end of the turn
    (`gateway/tests/test_artifacts.py::test_write_tool_path_is_collected`,
    `::test_newest_viewable_opens_at_finish_only`), the app's card choices
    mapping to the exact answers
    (`app/Tests/PorticoTests/CardTests.swift::testPermissionChoicesMapToDecisionAndScope`)
    and auto-open in the app
    (`app/Tests/PorticoTests/ArtifactOpenTests.swift::testAutoOpenRespectsSettingAndOpenFlag`).
  - Not automated: a real model asking, and the agent's own words after a deny.

### 3. Ask a question the agent must put back to the user: a question card appears; the chosen answer reaches the agent.

- [ ] **manual — Larry.** Needs a credential in the environment.
  - Automated pieces: the question card round trip with the answers mapped
    into the engine's shape
    (`gateway/tests/test_cards.py::test_question_card_round_trip_maps_answers`,
    `gateway/tests/test_engine_translate.py::test_question_routes_to_on_question_and_returns_updated_input`)
    and the app's answer builder
    (`app/Tests/PorticoTests/CardTests.swift::testQuestionAnswersMapLabelsAndOther`).
  - Not automated: a real model choosing to ask.

### 4. Ask for a markdown report: it opens rendered in the viewer. Ask for a small HTML page served from a local port: the URL opens in the viewer. Turn auto-open off in settings: the next artifact appears in the history only.

- [ ] **manual — Larry.** Needs a credential in the environment.
  - Automated pieces: markdown rendered through the real `WKWebView` pane
    (`app/Tests/PorticoTests/WebPaneRenderTests.swift::testMarkdownRendersHeadingsAndRelativeImage`),
    a local URL in the reply reported as an artifact that opens
    (`gateway/tests/test_artifacts.py::test_localhost_url_in_text_opens`),
    auto-open off keeping the artifact in the history only
    (`app/Tests/PorticoTests/ArtifactOpenTests.swift::testAutoOpenRespectsSettingAndOpenFlag`,
    `::testNonViewableNeverAutoOpens`).
  - Not automated: a real model writing the report and serving the page.

### 5. Stop interrupts a running turn. Quit the app while a turn is running; the gateway keeps going; reopen, pick the chat, see the prior conversation and its artifacts, and continue it. A permission asked while the app was closed is waiting as a card on reopen. Two chats open at once, each with its own state word.

- [ ] **manual — Larry.** Needs a credential in the environment and a window.
  - Automated pieces, which together cover every protocol step of this flow
    model-free: stop interrupts and finishes `stopped`
    (`gateway/tests/test_turns.py::test_turn_stop_interrupts_and_finishes_stopped`);
    events while no app is attached are kept for reattach
    (`gateway/tests/test_turns.py::test_events_while_detached_are_kept_for_reattach`);
    the person's own words replay
    (`gateway/tests/test_turns.py::test_same_launch_replay_carries_user_text`,
    `app/Tests/PorticoTests/ConversationTests.swift::testSameLaunchReplayShowsThePersonsMessages`);
    a reopen after a gateway restart replays the transcript and artifacts
    (`gateway/tests/test_history.py::test_open_after_restart_replays_transcript_and_artifacts`)
    once, not duplicated
    (`app/Tests/PorticoTests/GatewayClientTests.swift::testEpochChangeTriggersFullHistoryRefetch`,
    `app/Tests/PorticoTests/ConversationTests.swift::testFullReplayAfterARestartDoesNotDuplicateTheBubble`);
    a card asked while detached is delivered on attach
    (`gateway/tests/test_cards.py::test_held_card_delivered_on_attach`,
    `::test_open_cards_replay_on_chat_open`); an answered card is not
    reopened by a replay
    (`gateway/tests/test_cards.py::test_answered_card_is_closed_in_a_ring_replay`);
    quit behaviour deciding whether the gateway is stopped
    (`app/Tests/PorticoTests/AppModelTests.swift::testQuitBehaviourDecidesWhetherTheGatewayIsStopped`);
    the state words exact and per chat
    (`gateway/tests/test_chats.py::test_state_words_exact`,
    `app/Tests/PorticoTests/AppModelTests.swift::testChatStateWordShown`).
  - Not automated: the real quit and relaunch with a turn running on a real
    model, and two live chats side by side.

### 6. A folder whose `.claude/settings.json` has a deny hook (the probe's fixture) still has it fire through the app.

- [x] **Covered through the gateway by the opt-in live smoke**,
  `gateway/tests/test_live_smoke.py::test_live_smoke`: the probe's fixture
  (a `CLAUDE.md` codeword and a `PreToolUse` hook denying Bash) in a
  throwaway folder, the real SDK engine, the codeword in the streamed reply
  and the hook's denial reaching the model. **Needs a credential in the
  environment** (`PORTICO_LIVE=1`); skipped otherwise. Passed on this
  machine when it was written (2026-10-27). Model-free: `setting_sources`
  defaults to `["project"]` and an empty list is refused
  (`gateway/tests/test_config.py::test_empty_setting_sources_refused_with_exact_message`,
  `gateway/tests/test_turns.py::test_new_chat_starts_engine_in_folder_with_project_setting_sources`).
  - Still manual — Larry: the same fixture driven from the app window
    rather than the gateway's socket.

### 7. Tests that need no model: gateway tests against a fake engine (permission round trip, no-client deny, empty settings sources refused, token rejected, artifact detection from tool events and text, producer endpoint); Swift tests decoding every protocol example; one opt-in live smoke test like the probe.

- [x] **Covered.** Each named item, by test:
  - permission round trip: `gateway/tests/test_cards.py::test_permission_card_round_trip_allow_once`
  - no-client deny: `gateway/tests/test_cards.py::test_no_app_attached_holds_then_denies_with_message`
  - empty settings sources refused: `gateway/tests/test_config.py::test_empty_setting_sources_refused_with_exact_message`
  - token rejected: `gateway/tests/test_server.py::test_connect_without_token_is_401`,
    `gateway/tests/test_artifacts.py::test_producer_endpoint_opens_immediately_and_needs_token`
  - artifact detection from tool events and text:
    `gateway/tests/test_artifacts.py::test_write_tool_path_is_collected`,
    `::test_url_and_named_path_in_streamed_text_are_reported`,
    `::test_artifact_outside_folder_is_still_reported`
  - producer endpoint: `gateway/tests/test_artifacts.py::test_producer_endpoint_opens_immediately_and_needs_token`,
    `::test_producer_works_while_no_app_is_attached`
  - Swift decoding every protocol example:
    `app/Tests/PorticoTests/ProtocolExamplesTests.swift::testEveryServerExampleDecodes`,
    `::testEveryServerExampleRoundTrips`, `::testEveryClientExampleRoundTrips`
  - one opt-in live smoke: `gateway/tests/test_live_smoke.py::test_live_smoke`
  - The five Review Focus cases from the plan are tests too:
    `test_artifact_outside_folder_is_still_reported`,
    `testEpochChangeTriggersFullHistoryRefetch`,
    `test_stale_card_answer_is_rejected_not_crash`,
    `test_send_with_missing_attachment_is_refused`,
    `test_before_first_chat_times_out_and_refuses_chat`.

### 8. `doctor` reports a missing key, a stale token file, a busy port, each in one line.

- [ ] **Partly covered; the rest manual — Larry.**
  - Covered: a missing credential, a token file with the wrong mode, and a
    stale ledger (its pid gone, or alive with nothing listening on its port),
    each on one line, exit 1 on failure
    (`gateway/tests/test_doctor.py::test_doctor_reports_each_failure_in_one_line`,
    `::test_doctor_ledger_port_not_listening_is_stale`,
    `::test_doctor_cli_exits_nonzero_on_failure`).
  - Not a doctor check: "a busy port" in the sense of the gateway's chosen
    port being taken by another process. The gateway picks a free port at
    launch (`--port 0`), a second gateway on the same state directory is
    refused by the lock
    (`gateway/tests/test_lifecycle.py::test_second_instance_refused`), and
    the doctor reports the ledger's port when nothing listens on it. Larry
    decides whether that reading of "busy port" meets the threshold or a
    dedicated check is wanted; recorded here rather than guessed.

### 9. With a root configured, browse to a markdown file in the tree, open it in the viewer, add it to the chat, and the agent's reply shows it read that file.

- [ ] **manual — Larry.** Needs a credential in the environment.
  - Automated pieces: roots listed from `hello` and the tree filled from
    `files.list`
    (`gateway/tests/test_config.py::test_hello_carries_brand_actions_roots_and_protocol_1`,
    `gateway/tests/test_files.py::test_lists_root_level_dirs_first`,
    `app/Tests/PorticoTests/AppModelTests.swift::testFilesListRequestsAndRepliesFillTheTree`);
    a file from the tree shown in the viewer
    (`app/Tests/PorticoTests/AppModelTests.swift::testOpenFileFromTreeShowsInViewer`);
    an attachment appended to the message in the exact protocol form
    (`gateway/tests/test_turns.py::test_attachment_appended_in_exact_form`,
    `app/Tests/PorticoTests/ConversationTests.swift::testSendMessageEmitsMessageSendWithAttachmentsAndClearsDraft`).
  - Not automated: the agent's reply showing it read the file.

## Left for a person at the screen

Checks 1, 2, 3, 4, 5 and 9 in full, the app-window half of 6, and the
"busy port" reading of 8. All but the busy-port question need a provider
credential in the environment (`~/.portico/env` or the shell).
