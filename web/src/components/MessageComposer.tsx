"use client";

/**
 * The composer for messages.send (migration 0008): one target (everyone, teams, a language with a
 * minimum level, or named people), optionally only those clocked in now, a title, a text and the
 * urgency. The recipients are resolved by the database at send time and the answer says how many.
 * Names of people are staff data the sender already sees on Team hours; nothing here is customer data.
 */
import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import type { Copy } from "@/lib/copy";
import type { MessageTarget, MessageUrgency, SkillInfo, TeamInfo, TeamPerson } from "@/lib/data";
import { BODY_MAX, TITLE_MAX } from "@/lib/messages";
import { Button, Card, Notice } from "./primitives";

type Mode = "everyone" | "teams" | "language" | "users";
const HEADERS = { "content-type": "application/json", "x-cma-request": "1" } as const;

export function MessageComposer({ teams, languages, people, copy }: { teams: TeamInfo[]; languages: SkillInfo[]; people: TeamPerson[]; copy: Copy["messages"] }) {
  const router = useRouter();
  const [mode, setMode] = useState<Mode>("everyone");
  const [teamKeys, setTeamKeys] = useState<string[]>([]);
  const [skill, setSkill] = useState<string>(languages[0]?.key ?? "");
  const [minLevel, setMinLevel] = useState<string>("");
  const [userIds, setUserIds] = useState<string[]>([]);
  const [onlyClockedIn, setOnlyClockedIn] = useState(false);
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [urgency, setUrgency] = useState<MessageUrgency>("normal");
  const [result, setResult] = useState<{ tone: "info" | "warning"; text: string } | null>(null);
  const [pending, startTransition] = useTransition();

  const levels = languages.find((l) => l.key === skill)?.levels ?? [];
  const toggle = (list: string[], v: string) => (list.includes(v) ? list.filter((x) => x !== v) : [...list, v]);

  function target(): MessageTarget | null {
    const only = onlyClockedIn ? { onlyClockedIn: true as const } : {};
    if (mode === "everyone") return { everyone: true, ...only };
    if (mode === "teams") return teamKeys.length ? { teams: teamKeys, ...only } : null;
    if (mode === "language") return skill ? { language: { skill, minLevel: minLevel ? Number(minLevel) : null }, ...only } : null;
    return userIds.length ? { users: userIds, ...only } : null;
  }
  const ready = title.trim().length > 0 && title.trim().length <= TITLE_MAX && body.length <= BODY_MAX && target() !== null;

  function send() {
    const t = target();
    if (!t) return;
    setResult(null);
    startTransition(async () => {
      const res = await fetch("/api/v1/messages", { method: "POST", headers: HEADERS, body: JSON.stringify({ title: title.trim(), body, urgency, target: t }) });
      if (res.status === 201) {
        const { data } = (await res.json()) as { data: { recipients: number } };
        setResult({ tone: "info", text: data.recipients === 1 ? copy.sentToOne : copy.sentTo.replace("{n}", String(data.recipients)) });
        setTitle("");
        setBody("");
        setUrgency("normal");
        router.refresh();
      } else {
        const payload = (await res.json().catch(() => null)) as { error?: { code?: string } } | null;
        setResult({ tone: "warning", text: res.status === 400 && payload?.error?.code === "invalid" ? copy.nobody : copy.sendFailed });
      }
    });
  }

  const radio = (value: Mode, label: string) => (
    <label key={value} className="inline-flex h-10 cursor-pointer items-center gap-2 rounded-button border border-p4a-border px-3 text-body has-[:checked]:border-p4a-deepblue has-[:checked]:bg-p4a-bgblue">
      <input type="radio" name="target" value={value} checked={mode === value} onChange={() => setMode(value)} className="accent-p4a-deepblue" />
      {label}
    </label>
  );

  return (
    <Card title={copy.composeTitle}>
      <fieldset className="flex flex-col gap-3">
        <legend className="mb-2 text-small font-semibold text-p4a-heading">{copy.to}</legend>
        <div className="flex flex-wrap gap-2">
          {radio("everyone", copy.toEveryone)}
          {teams.length ? radio("teams", copy.toTeams) : null}
          {languages.length ? radio("language", copy.toLanguage) : null}
          {people.length ? radio("users", copy.toPeople) : null}
        </div>
        {mode === "teams" ? (
          <div className="flex flex-wrap gap-2" data-testid="target-teams">
            {teams.map((t) => (
              <label key={t.key} className="inline-flex h-9 cursor-pointer items-center gap-2 rounded-button border border-p4a-border px-3 text-small has-[:checked]:border-p4a-deepblue has-[:checked]:bg-p4a-bgblue">
                <input type="checkbox" checked={teamKeys.includes(t.key)} onChange={() => setTeamKeys((k) => toggle(k, t.key))} className="accent-p4a-deepblue" />
                {t.name}
              </label>
            ))}
          </div>
        ) : null}
        {mode === "language" ? (
          <div className="flex gap-3" data-testid="target-language">
            <select value={skill} onChange={(e) => { setSkill(e.target.value); setMinLevel(""); }} className="h-10 rounded-button border border-p4a-border bg-white px-3 text-body" aria-label={copy.toLanguage}>
              {languages.map((l) => <option key={l.key} value={l.key}>{l.name}</option>)}
            </select>
            <select value={minLevel} onChange={(e) => setMinLevel(e.target.value)} className="h-10 rounded-button border border-p4a-border bg-white px-3 text-body" aria-label={copy.minLevel}>
              <option value="">{copy.anyLevel}</option>
              {levels.map((l) => <option key={l.level} value={String(l.level)}>{l.name}</option>)}
            </select>
          </div>
        ) : null}
        {mode === "users" ? (
          <div className="grid max-h-56 grid-cols-2 gap-2 overflow-y-auto rounded-button border border-p4a-border p-3" data-testid="target-users">
            {people.length === 0 ? <p className="text-small text-p4a-muted">{copy.noPeople}</p> : null}
            {people.map((p) => (
              <label key={p.userId} className="inline-flex cursor-pointer items-center gap-2 text-small">
                <input type="checkbox" checked={userIds.includes(p.userId)} onChange={() => setUserIds((u) => toggle(u, p.userId))} className="accent-p4a-deepblue" />
                <span>{p.displayName}</span>
                <span className="text-p4a-grey">· {p.organisationName}</span>
              </label>
            ))}
          </div>
        ) : null}
        <label className="inline-flex cursor-pointer items-center gap-2 text-small">
          <input type="checkbox" checked={onlyClockedIn} onChange={(e) => setOnlyClockedIn(e.target.checked)} className="accent-p4a-deepblue" />
          {copy.onlyClockedIn}
        </label>
      </fieldset>

      <div className="mt-6 flex flex-col gap-4">
        <label className="flex flex-col gap-1 text-small font-semibold text-p4a-heading">
          {copy.titleLabel}
          <input value={title} maxLength={TITLE_MAX} onChange={(e) => setTitle(e.target.value)} className="h-10 rounded-button border border-p4a-border px-3 text-body font-normal text-p4a-body" />
        </label>
        <label className="flex flex-col gap-1 text-small font-semibold text-p4a-heading">
          {copy.bodyLabel}
          <textarea value={body} maxLength={BODY_MAX} rows={4} onChange={(e) => setBody(e.target.value)} className="rounded-button border border-p4a-border px-3 py-2 text-body font-normal text-p4a-body" />
          <span className="text-caption font-normal text-p4a-grey tabular">{body.length} / {BODY_MAX}</span>
        </label>
        <fieldset className="flex flex-col gap-2">
          <legend className="mb-1 text-small font-semibold text-p4a-heading">{copy.urgencyLabel}</legend>
          <label className="inline-flex cursor-pointer items-center gap-2 text-body">
            <input type="radio" name="urgency" checked={urgency === "normal"} onChange={() => setUrgency("normal")} className="accent-p4a-deepblue" /> {copy.urgencyNormal}
          </label>
          <label className="inline-flex cursor-pointer items-center gap-2 text-body">
            <input type="radio" name="urgency" checked={urgency === "urgent"} onChange={() => setUrgency("urgent")} className="accent-p4a-deepblue" /> {copy.urgencyUrgent}
          </label>
        </fieldset>
        <div className="flex items-center gap-4">
          <Button variant="primary" size="md" onClick={send} disabled={!ready || pending}>{copy.send}</Button>
          <span className="text-caption text-p4a-grey">{copy.referencesOnly}</span>
        </div>
        {result ? <Notice tone={result.tone}>{result.text}</Notice> : null}
      </div>
    </Card>
  );
}
