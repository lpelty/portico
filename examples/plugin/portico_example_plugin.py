"""An example Portico plug-in: a log step of its own, and a note in ``hello``.

Copy it somewhere outside the Portico checkout, then name it in
``config.toml``:

    plugins = ["portico_example_plugin"]
    plugin_paths = ["~/portico-plugins"]

It replaces the default log step (sending ``log_prompt``) with its own
message, and adds a capability to ``hello`` so the doctor and the app can
see it is loaded. A real deployment's plug-in would run its own logging
here: a skill, a script, a call to its memory service.
"""

from __future__ import annotations

PORTICO_PLUGIN_API = 1

LOG_MESSAGE = (
    "This session is ending. Append a short summary of what we did and what is "
    "still open to SESSION-LOG.md in this folder, then reply with one line."
)


def on_hello(hello):
    """Say the plug-in is loaded; everything else in ``hello`` stays as configured."""
    return hello.model_copy(update={"capabilities": [*hello.capabilities, "example.plugin"]})


async def on_renew(ctx, chat):
    """Ask the agent to log the session; logged only when that turn finished cleanly."""
    if chat.title:
        message = f"{LOG_MESSAGE} The session began with: {chat.title}"
    else:
        message = LOG_MESSAGE
    outcome = await ctx.send(message)
    return outcome == "done"
