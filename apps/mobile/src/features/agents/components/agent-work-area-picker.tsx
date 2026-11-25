import { useQuery } from "@tanstack/react-query";
import { Button, Typography } from "heroui-native";
import { useState } from "react";
import { View } from "react-native";
import { workAreaMessages } from "@/features/agents/model/agent-work-area";
import { useQueryScope } from "@/features/auth/context/mobile-session-context";
import {
  useMobileWorkspaceActions,
  useMobileWorkspaceSelector,
} from "@/features/workspace/context/mobile-workspace-context";
import { MenuView } from "@/shared/components/menu-view";
import { useText } from "@/shared/lib/text";

export function AgentWorkAreaPicker({ serverId, onConfirm }: { serverId: string; onConfirm: (area: string) => void }) {
  const { t, sourceText } = useText();
  const { loadAgentWorkAreas } = useMobileWorkspaceActions();
  const canPick = useMobileWorkspaceSelector((workspace) =>
    workspace.servers.some((server) => server.id === serverId && server.role === "owner"),
  );
  const scope = useQueryScope();
  const [choice, setChoice] = useState<string | null>(null);
  const query = useQuery({
    queryKey: ["agent-work-areas", ...scope, serverId],
    queryFn: () => loadAgentWorkAreas(serverId),
    enabled: canPick,
    retry: false,
  });
  const areas = query.data ?? [];
  const selected = choice !== null && areas.includes(choice) ? choice : null;
  const label = sourceText(workAreaMessages["mobile.agent.workArea.choose"]);

  return (
    <View className="gap-3">
      <Typography.Heading type="h3" accessibilityRole="header">
        {sourceText(workAreaMessages["mobile.agent.workArea.title"])}
      </Typography.Heading>
      {!canPick ? (
        <Typography.Paragraph accessibilityRole="alert">
          {sourceText(workAreaMessages["mobile.agent.workArea.ownerRequired"])}
        </Typography.Paragraph>
      ) : query.isPending || query.isFetching ? (
        <Typography.Paragraph accessibilityLiveRegion="polite">{t("common.loading")}</Typography.Paragraph>
      ) : query.isError || areas.length === 0 ? (
        <>
          <Typography.Paragraph accessibilityRole="alert">
            {sourceText(
              workAreaMessages[query.isError ? "mobile.agent.workArea.loadFailed" : "mobile.agent.workArea.empty"],
            )}
          </Typography.Paragraph>
          <Button variant="ghost" onPress={() => void query.refetch()}>
            <Button.Label>{t("common.retry")}</Button.Label>
          </Button>
        </>
      ) : (
        <>
          <MenuView
            actions={areas.map((area) => ({ id: area, title: area, state: selected === area ? "on" : "off" }))}
            onPressAction={({ nativeEvent }) => {
              if (areas.includes(nativeEvent.event)) setChoice(nativeEvent.event);
            }}
          >
            <View
              accessible
              accessibilityRole="button"
              accessibilityLabel={label}
              accessibilityValue={selected ? { text: selected } : undefined}
              className="min-h-12 justify-center rounded-xl border border-border px-4 py-2"
            >
              <Typography.Paragraph>{selected ?? label}</Typography.Paragraph>
            </View>
          </MenuView>
          <Button
            isDisabled={selected === null}
            onPress={() => {
              if (selected !== null) onConfirm(selected);
            }}
          >
            <Button.Label>{t("common.continue")}</Button.Label>
          </Button>
        </>
      )}
    </View>
  );
}
