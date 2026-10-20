import { Inbox } from "@/components/Inbox";
import { Shell } from "@/components/Shell";
import { LinkButton, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock } from "@/lib/data";
import { INBOX_LIMIT_DEFAULT, WITHDRAW_PERMISSION } from "@/lib/messages";
import { resolve } from "../access";

/**
 * Messages (migration 0008): the person's own inbox, for everyone with a role. Reading the page
 * returns the latest messages (their first return sets the delivered time) and never marks anything
 * read: that is the person's own action. A sender sees the button to the composer; a person holding
 * messages.withdraw deletes a message for everyone (addition 0008z).
 */
export default async function MessagesPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const canSend = me.permissions.includes("messages.send");
  const inbox = await data().listMyMessages(me, null, INBOX_LIMIT_DEFAULT);

  return (
    <Shell copy={copy} me={me} active="messages">
      <PageTitle>{copy.messages.title}</PageTitle>
      {canSend ? (
        <div className="mb-6">
          <LinkButton href="/messages/send" variant="primary" data-shortcut="n" shortcut="N">{copy.messages.newMessage}</LinkButton>
        </div>
      ) : null}
      <Inbox initial={inbox} copy={copy.messages} timeZone={me.timeZone} locale={me.locale} canWithdraw={me.permissions.includes(WITHDRAW_PERMISSION)} />
      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
