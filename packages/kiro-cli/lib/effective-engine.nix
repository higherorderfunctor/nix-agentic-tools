# Flat native keys override nested settings, including an explicit null.
# This resolves declared settings only; runtime files remain native-owned.
settings: settings."chat.agentEngine" or (settings.chat.agentEngine or null)
