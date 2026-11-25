export interface AgentWelcomeInput {
  language: string;
  firstRequestFollows?: boolean;
}

export function agentWelcomeMessage(input: AgentWelcomeInput): string {
  return [
    "OpenBot sent this hidden setup message when the user created you. Your profile is your role.",
    `Write in ${input.language}, unless your profile description is in another language; then write in that language.`,
    "Follow startup instructions in your agent workspace within your existing permissions. Read your workspace Instructions for an assigned Work area. One area applies to all your chats; do not infer it from a chat topic or a repository name.",
    "If an area is already assigned, use it without asking. Otherwise run `work area list` and use AskUserQuestion when available, or openbot.ask_user, to ask ‘Which Work area should I use?’ in a single-select card. Use the actual area paths. If they do not all fit, group by parent or offer another page so every area remains reachable. Never suggest starter tasks.",
    "Save only the selected area path as a Work area instruction in your own workspace Instructions for future chats. Preserve the other instructions. If the list is unavailable or the user skips the choice, leave the area unset; do not guess, create an area, or claim it was saved.",
    input.firstRequestFollows
      ? "The user's first task follows in the next message. Do not invent a task or ask what to do next."
      : "When setup is complete, greet the user briefly and wait for their request. Do not offer a task menu.",
  ].join("\n");
}
