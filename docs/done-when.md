# Done-when checks, v0.1.0

The nine checks from the design's "Done when" list. A box is ticked only
when an automated test or probe in this repo demonstrably covers it, and
the test is cited. For a check whose text names the window, the tick means
the gateway half ran live against a real model and passed, and the line
says what the window itself still owes a person at the screen. Where a
check cannot run without a provider credential, it says so.

Baseline on 2026-10-28, with the live checks folded in and run (measured
at HEAD `abc9ea8`, tree clean, before this docs commit):

- `cd gateway && uv run pytest -q`: 199 passed, 25 skipped in 6.4s (the
  skips are the opt-in live smoke and the six opt-in live check files below)
- `cd app && swift test`: Executed 89 tests, with 1 test skipped (the opt-in
  live hello handshake) and 0 failures (0 unexpected) in 4.623 (4.634)
  seconds; no `error:` or `failed` lines
- `tests/test_distribution.py`: 2 passed in 0.02s
- Live, with a credential in the environment (`PORTICO_LIVE=1`): 25 passed
  in 320.43s (0:05:20) — `tests/test_live_smoke.py` plus
  `tests/test_live_check1/2/3/4/5/9.py`
- Forbidden-token grep over `git ls-files` (excluding
  `tests/test_distribution.py`): 0 matches
- All green.

Opt-in live tests, when a credential is in the environment:

- `cd gateway && PORTICO_LIVE=1 uv run pytest tests/test_live_smoke.py -v`
- `cd gateway && PORTICO_LIVE=1 uv run pytest tests/test_live_check1.py tests/test_live_check2.py tests/test_live_check3.py tests/test_live_check4.py tests/test_live_check5.py tests/test_live_check9.py -v`
  — the gateway half of checks 1, 2, 3, 4, 5 and 9 against the real model
  (24 tests; every one passed on this machine on 2026-10-28). Each file
  says in its docstring what it leaves to a person at the screen.
- `cd app && PORTICO_GATEWAY_URL=ws://127.0.0.1:<port> PORTICO_GATEWAY_TOKEN=<token> swift test --filter testLiveHelloHandshake`

## The checks

### 1. Fresh clone: one command starts the gateway; `swift run` opens the app; pick a folder; send a message; the reply streams.

- [x] **Gateway half demonstrated live** on 2026-10-28 by
  `gateway/tests/test_live_check1.py` (4 passed): a fresh clone installed
  through its own `bin/`, started with one command, a folder picked on
  `chat.new`, a message sent and the reply streamed. **Still at the screen —
  Larry:** the window itself (`swift run`, picking the folder in it, the
  reply streaming on screen).
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
  - Live, opt-in (`gateway/tests/test_live_check1.py`): a `git clone` of
    HEAD through `bin/install` (gateway venv and `swift build -c release`),
    `bin/doctor` passing from the clone and naming a missing credential, the
    clone's `bin/portico-gateway run` detached with its ready line and
    ledger, health without a token and websocket 401 without one, a real
    reply streamed over the protocol, and `gateway.stop` closing 1001,
    exiting 0 and clearing the ledger
    (`::test_a_doctor_passes_from_the_clone_and_names_a_missing_credential`,
    `::test_b_ready_line_ledger_health_and_token_gate`,
    `::test_c_conversation_streams_a_reply`,
    `::test_d_gateway_stop_exits_and_clears_the_ledger`).
  - Left to a person at the screen: the real window (`swift run`) and
    picking a folder in it.

### 2. Ask for a file write: a permission card appears; deny leaves no file and the agent says it was denied; allow writes it, and the file opens in the viewer on its own.

- [x] **Gateway half demonstrated live** on 2026-10-28 by
  `gateway/tests/test_live_check2.py` (3 passed): the real model asks a
  permission card for the write, a deny leaves no file and the agent says it
  was denied, an allow writes it and the markdown artifact is reported
  `open=true`. **Still at the screen — Larry:** the card in the window and
  the file opening in the viewer.
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
  - Live, opt-in (`gateway/tests/test_live_check2.py`): the real model
    asking a Write card, `waiting on you` after it, a deny leaving no file
    with the agent saying so, an allow writing the file and one markdown
    artifact `open=true` before `turn.finished`, and a chat-scoped allow on
    Write covering the next write in that chat with no card (D16)
    (`::test_a_deny_leaves_no_file_and_the_agent_says_so`,
    `::test_b_allow_once_writes_and_the_markdown_artifact_opens`,
    `::test_c_chat_scoped_allow_covers_the_next_write_in_the_chat`).
  - Left to a person at the screen: the card in the window and the file
    opening in the viewer.

### 3. Ask a question the agent must put back to the user: a question card appears; the chosen answer reaches the agent.

- [x] **Gateway half demonstrated live** on 2026-10-28 by
  `gateway/tests/test_live_check3.py` (3 passed): the real model puts a
  question back, a question card arrives in the protocol's shape, and the
  chosen answer reaches the agent for single-select, multi-select and
  "Other" free text. **Still at the screen — Larry:** the card in the
  window and picking the answer there.
  - Automated pieces: the question card round trip with the answers mapped
    into the engine's shape
    (`gateway/tests/test_cards.py::test_question_card_round_trip_maps_answers`,
    `gateway/tests/test_engine_translate.py::test_question_routes_to_on_question_and_returns_updated_input`)
    and the app's answer builder
    (`app/Tests/PorticoTests/CardTests.swift::testQuestionAnswersMapLabelsAndOther`).
  - Live, opt-in (`gateway/tests/test_live_check3.py`): the real model
    calling its question tool, the question card's shape and lifecycle, and
    the chosen answer reaching the agent for single-select, multi-select
    and "Other" free text
    (`::test_single_select_answer_reaches_the_agent`,
    `::test_multi_select_answers_reach_the_agent`,
    `::test_other_free_text_reaches_the_agent`).
  - Left to a person at the screen: the card in the window.

### 4. Ask for a markdown report: it opens rendered in the viewer. Ask for a small HTML page served from a local port: the URL opens in the viewer. Turn auto-open off in settings: the next artifact appears in the history only.

- [x] **Gateway half demonstrated live** on 2026-10-28 by
  `gateway/tests/test_live_check4.py` (4 passed): the real model writes a
  markdown report that is reported `open=true` at turn end and replays on
  `chat.open`; it writes and serves an HTML page on a local port and the URL
  is reported `open=true` with the HTML file listed only; the producer
  endpoint opens an artifact mid-turn at once. **Still at the screen —
  Larry:** the report rendered and the URL shown in the viewer, and
  auto-open off in settings keeping the next artifact in the history only.
  - Automated pieces: markdown rendered through the real `WKWebView` pane
    (`app/Tests/PorticoTests/WebPaneRenderTests.swift::testMarkdownRendersHeadingsAndRelativeImage`),
    a local URL in the reply reported as an artifact that opens
    (`gateway/tests/test_artifacts.py::test_localhost_url_in_text_opens`),
    auto-open off keeping the artifact in the history only
    (`app/Tests/PorticoTests/ArtifactOpenTests.swift::testAutoOpenRespectsSettingAndOpenFlag`,
    `::testNonViewableNeverAutoOpens`).
  - Live, opt-in (`gateway/tests/test_live_check4.py`): the real model
    writing `report.md` (one markdown artifact `open=true` at turn end,
    replayed by `chat.open`), writing and serving an HTML page on a local
    port (the URL artifact opens, the HTML file is listed only), the
    producer endpoint mid-turn opening at once, and a reply that merely
    names an existing viewable path (D15)
    (`::test_a_markdown_report_opens_at_turn_end_and_replays`,
    `::test_b_html_page_and_local_url_open`,
    `::test_c_producer_mid_turn_opens_immediately`,
    `::test_d_prose_naming_an_existing_viewable_path_reports_it`).
  - Left to a person at the screen: the viewer rendering, and auto-open off
    in settings (an app setting; the gateway reports `open` the same either
    way).

### 5. Stop interrupts a running turn. Quit the app while a turn is running; the gateway keeps going; reopen, pick the chat, see the prior conversation and its artifacts, and continue it. A permission asked while the app was closed is waiting as a card on reopen. Two chats open at once, each with its own state word.

- [x] **Gateway half demonstrated live** on 2026-10-28 by
  `gateway/tests/test_live_check5.py` (6 passed) against a real detached
  gateway process and the real model: stop interrupts a running turn; the
  client goes away mid-turn and the gateway keeps going and finishes the
  writes; reattach replays the conversation and its artifacts gaplessly and
  the chat continues; a permission asked while nothing was attached is
  waiting as a card on reopen; two chats each carry their own state word;
  a gateway restart replays the transcript and resumes the session.
  **Still at the screen — Larry:** quitting and reopening the real window
  with a turn running.
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
  - Live, opt-in (`gateway/tests/test_live_check5.py`), against a real
    detached `bin/portico-gateway run` process and the real model: `turn.stop`
    interrupting a running turn, `chat.stop` giving `stopped` and the next
    send resuming, a detach mid-turn with the gateway finishing the writes
    and a gapless `since` replay with the artifacts, a permission asked
    while detached waiting as a card on reopen, two chats with their own
    state words, and `gateway.stop` then a restart replaying the transcript
    and resuming the session
    (`::test_a_turn_stop_interrupts_a_running_turn`,
    `::test_a2_chat_stop_gives_stopped_then_the_next_send_resumes`,
    `::test_b_detach_mid_turn_then_reattach_replays_gaplessly`,
    `::test_c_a_card_asked_while_detached_is_replayed_on_reopen`,
    `::test_d_two_chats_each_with_their_own_state_word`,
    `::test_e_a_restart_replays_the_transcript_and_resumes_the_session`).
  - Left to a person at the screen: quitting and reopening the real window
    with a turn running.

### 6. A folder whose `.claude/settings.json` has a deny hook (the probe's fixture) still has it fire through the app.

- [x] **Covered through the gateway by the opt-in live smoke**,
  `gateway/tests/test_live_smoke.py::test_live_smoke`: the probe's fixture
  (a `CLAUDE.md` codeword and a `PreToolUse` hook denying Bash) in a
  throwaway folder, the real SDK engine, the codeword in the streamed reply
  and the hook's denial reaching the model. **Needs a credential in the
  environment** (`PORTICO_LIVE=1`); skipped otherwise. Passed on this
  machine when it was written (2026-10-27) and again in the 2026-10-28 live
  run. Model-free: `setting_sources`
  defaults to `["project"]` and an empty list is refused
  (`gateway/tests/test_config.py::test_empty_setting_sources_refused_with_exact_message`,
  `gateway/tests/test_turns.py::test_new_chat_starts_engine_in_folder_with_project_setting_sources`).
  - Still at the screen — Larry: the same fixture driven from the app
    window rather than the gateway's socket.

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

- [x] **Gateway half demonstrated live** on 2026-10-28 by
  `gateway/tests/test_live_check9.py` (4 passed): a configured root arrives
  in `hello`, `files.list` walks it in the documented shape, a file from the
  root attached to a message is read by the real model and its reply shows
  it, and spaced and unicode paths both work. **Still at the screen —
  Larry:** browsing the tree, the file in the viewer and "Add to chat" in
  the window.
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
  - Live, opt-in (`gateway/tests/test_live_check9.py`): a root from a
    `config.toml` carried in `hello`, `files.list` in the documented shape
    with escapes and unknowns refused, an attached file read by the real
    model with the reply showing it, a missing attachment refused before
    any turn, and spaced and unicode paths both read
    (`::test_a_hello_carries_the_root_and_files_list_has_the_documented_shape`,
    `::test_b_an_attached_file_is_read_by_the_agent`,
    `::test_c_a_missing_attachment_is_refused_before_any_turn`,
    `::test_d_a_spaced_path_and_a_unicode_path_are_both_read`).
  - Left to a person at the screen: browsing the tree, the file in the
    viewer and "Add to chat" in the window.

## Left for a person at the screen

The app-window half of checks 1, 2, 3, 4, 5, 6 and 9 — the gateway half of
each was demonstrated live on 2026-10-28 (25 live tests, every one passed,
listed above) — and the "busy port" reading of 8. The window checks need a
provider credential in the environment (`~/.portico/env` or the shell); the
busy-port question needs only a decision.
