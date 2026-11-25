# OpenBot built-in tool inventory

These are the registered names in the fork's `BUILTIN_TOOL_CATALOG`, grouped by use for review. This is not a list of permissions or the set advertised to every model. Provider-native tools, installed MCP apps, and shell CLIs are separate. After an upstream sync, compare this list with `src/backend/agent/tool-catalog.ts` and its imported definitions.

## `openbot` (121)

| Use | Tools |
| --- | --- |
| Channel conversation and tasks | `list_channels`, `create_channel`, `update_channel`, `send_to_channel`, `channel_history`, `channel_assign`, `channel_transfer`, `channel_result`, `channel_reply`, `channel_cancel`, `channel_add_member`, `channel_remove_member`, `channel_set_instructions` |
| Channel memory and routines | `channel_remember`, `channel_forget_memory`, `channel_list_routines`, `channel_create_routine`, `channel_update_routine`, `channel_delete_routine` |
| External messaging | `messaging_remember`, `messaging_forget_memory`, `messaging_history`, `messaging_list_places`, `messaging_post` |
| Chat history | `history_search`, `history_read` |
| Structured data | `list_tables`, `query_data`, `execute_data`, `delete_table` |
| Skills | `create_skill`, `revise_skill`, `list_local_skills`, `read_local_skill`, `install_local_skill`, `set_skill_enabled`, `uninstall_skill` |
| Workflows | `list_routine_flows`, `connect_routine_agents`, `disconnect_routine_agents`, `list_workflows`, `read_workflow`, `edit_workflow`, `delete_workflow`, `run_workflow`, `read_workflow_runs` |
| Customer records | `crm_find`, `crm_customer`, `crm_payments`, `crm_propose` |
| Integrations | `list_mcp_servers`, `save_mcp_server`, `test_mcp_server`, `set_mcp_server_enabled`, `remove_mcp_server`, `suggest_marketplace_app` |
| Sites | `list_sites`, `publish_site`, `replace_site`, `delete_site` |
| Files, media and display | `attach_files_to_response`, `list_library_folders`, `organize_library`, `html_preview`, `html_render`, `set_backdrop`, `list_capture_sources`, `capture_screen`, `read_video`, `read_image` |
| Web and server setup | `web_search`, `create_server_install_command` |
| Sidebar sections | `list_sections`, `create_section`, `rename_section`, `delete_section`, `assign_agent_section` |
| Agents and profiles | `list_agents`, `list_models`, `interrupt_agent`, `read_agent`, `create_agent`, `update_profile`, `update_agents`, `set_browser_profile`, `set_commit_co_author`, `delete_agent`, `start_new_chat` |
| Routines and waits | `list_routines`, `create_routine`, `create_webhook_routine`, `update_webhook_routine`, `update_routine`, `delete_routine`, `test_routine`, `routine_no_update`, `routine_report_failure`, `await_event`, `close_wait`, `list_waits` |
| Delegation and messages | `start_task`, `message_task`, `close_task`, `send_message` |
| Private OpenBot memory (hidden when off) | `search_memories`, `list_memories`, `set_memory_inclusion`, `remember`, `forget_memory` |
| Questions, acknowledgments and chat actions | `ask_user`, `acknowledge_request`, `ask_ui`, `react_to_user_message`, `pin_message` |
| API key management | `request_api_key`, `list_api_keys`, `save_api_key`, `remove_api_key` |
| Settings and feedback | `show_setting`, `send_feedback`, `withdraw_feedback` |

## `openbot_browser` (34)

| Use | Tools |
| --- | --- |
| Tabs and navigation | `open`, `list_tabs`, `status`, `navigate`, `close_tab` |
| Inspection and actions | `snapshot`, `click`, `type`, `fill_fields`, `press`, `hover`, `scroll`, `select_option`, `set_checked`, `drag`, `upload_files`, `wait_for`, `evaluate`, `set_environment`, `act`, `screenshot`, `run_script`, `handle_dialog` |
| Protected interactions | `submit_secret`, `list_logins`, `list_vault_items`, `save_vault_item`, `request_vault_item`, `delete_vault_item`, `fill_card`, `request_link_payment`, `request_takeover` |
| Recording | `recording_start`, `recording_stop` |

## Discovery

`tool_search`, `tool_describe`, and `tool_call` are three additional entry points, not part of the 155 above. Search can return the schema directly; otherwise describe the tool before calling it. Adapters differ in which tools they expose directly. Connected LifeOS MCP tools are discovered through the provider’s external MCP path, not OpenBot’s built-in search.
