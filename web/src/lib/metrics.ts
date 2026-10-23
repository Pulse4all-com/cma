/**
 * The metric catalog's pure logic (Configuration → Metrics): the registry of metric keys per page,
 * the page's gate, the anchor links the tile hints use, and the filter rule of the catalog page.
 * The catalog itself lives in docs/metrics/catalog.json; web/scripts/metrics-doc.mjs copies it into
 * src/lib/metrics-catalog.json for the build (the Docker build's context is web/) and generates
 * docs/metrics/METRICS.md from it; web/verify/metrics.mjs keeps the three in step.
 * No runtime imports, so the verifier runs this module with Node's type stripping.
 */

/** One entry of the catalog, as docs/metrics/schema.json defines it */
export interface MetricEntry {
  key: string;
  surface: "welcome" | "live" | "dashboard" | "report" | "configuration" | "agent" | "export" | "api";
  page: string;
  tile: string | null;
  title: { en: string; nl: string | null };
  definition: string;
  formula: string;
  unit: string;
  grain: readonly string[];
  sources: readonly {
    table: string;
    columns: readonly string[];
    owner: string;
    fed_by: string;
    cadence: string;
  }[];
  filters: readonly string[];
  time: string;
  comparison: string | null;
  settings: readonly { key: string; default: string; pulse4all: string }[];
  permissions: { anyOf: readonly string[]; perPerson: "email" | "orders" | "attempts" | "deals" | null };
  refresh: string;
  computed_in: {
    sql: readonly { object: string; migration: string }[];
    ts: readonly { file: string; export: string }[];
  };
  verify_sql: string | null;
  fixture_check: string;
  prerequisites: readonly { item: string; check: string | null }[];
  docs: readonly string[];
  status: readonly ("verified" | "discrepancy" | "ambiguous" | "prerequisite_missing" | "cadence_unconfirmed")[];
  notes: string;
}

export interface MetricCatalog {
  _about: string;
  entries: readonly MetricEntry[];
}

/** The permission that shows the page, the rail item and the tile hints' link */
export const METRICS_PERMISSION = "tenant.configure";

/** The catalog page's answer for a set of permissions: the page for the holder, a real 403 for everyone else */
export function metricsPageStatus(permissions: readonly string[]): 200 | 403 {
  return permissions.includes(METRICS_PERMISSION) ? 200 : 403;
}

/** The anchor of an entry on the catalog page: /configuration/metrics#calls.outbound_connected_share */
export function metricsHref(key: string): string {
  return `/configuration/metrics#${key}`;
}

/**
 * "How this is computed" on a tile's hint: the link for a person who may open the catalog page,
 * nothing for anyone else (the page would answer their 403)
 */
export function metricsMore(permissions: readonly string[], key: string, label: string): { href: string; label: string } | undefined {
  return permissions.includes(METRICS_PERMISSION) ? { href: metricsHref(key), label } : undefined;
}

/**
 * The metric keys each page shows, the registry web/verify/metrics.mjs checks against the catalog:
 * every key here must have a catalog entry, and every catalog entry on a page surface (welcome, live,
 * dashboard, report, agent) must be registered under its page. A new figure on a page is added here
 * and in docs/metrics/catalog.json in the same change, or verify:metrics fails the build.
 */
export const PAGE_METRIC_KEYS: Readonly<Record<string, readonly string[]>> = {
  "/": [
    "welcome.clock.state",
    "welcome.clock.status",
    "welcome.clock.clocked_in_at",
    "welcome.clock.worked_so_far",
    "welcome.clock.clocked_out_at",
    "welcome.needs_attention.days_not_clocked_out",
    "welcome.needs_attention.leads_past_target",
    "welcome.needs_attention.tickets_at_risk_or_breached",
    "welcome.needs_attention.tasks_overdue",
    "welcome.needs_attention.missed_callbacks",
    "welcome.waiting_for_you.total",
    "welcome.waiting_for_you.counts",
  ],
  "/live/board": [
    "live.people.group",
    "live.tiles.group_count",
    "live.tiles.clocked_out",
    "live.tiles.not_clocked_in",
    "live.people.shown_of_total",
    "live.people.since",
    "live.people.clocked_in_at",
    "live.people.clocked_out_at",
    "live.people.worked_so_far",
    "live.people.shift_today",
    "live.people.adherence_flag",
    "live.inbound.offered",
    "live.inbound.answered",
    "live.inbound.unanswered_share",
    "live.inbound.service_level",
    "live.inbound.avg_answer",
    "live.inbound.waiting_now",
    "live.inbound.longest_waiting",
    "live.missed.listed",
    "live.missed.missed_at",
    "live.missed.waiting",
    "live.missed.times_missed",
    "live.missed.anonymous_count",
    "live.follow_up_now.leads_open_not_called",
    "live.follow_up_now.leads_past_target",
    "live.follow_up_now.tickets_at_risk",
    "live.follow_up_now.tickets_breached",
    "live.follow_up_now.tasks_overdue",
    "live.follow_up_now.tasks_due_today",
  ],
  "/reports/dashboard": [
    "dashboard.time.worked_minutes",
    "dashboard.time.paid_minutes",
    "dashboard.time.productive_share",
    "dashboard.time.people",
    "dashboard.time.groups",
    "dashboard.time.per_status",
    "dashboard.time.per_day",
    "dashboard.time.per_person",
    "dashboard.time.capped_days_note",
    "dashboard.intake.leads",
    "dashboard.intake.deals_created",
    "dashboard.intake.tickets_created",
    "dashboard.intake.speed_to_lead",
    "dashboard.intake.calls",
    "dashboard.intake.first_orders",
    "dashboard.intake.callbacks_kept",
  ],
  "/roster/planner": [
    "roster.planner.planned_minutes_per_person",
    "roster.planner.headcount_per_day",
    "roster.planner.coverage",
    "roster.planner.week_state",
    "roster.planner.saved_week_shift_count",
  ],
  "/team/hours": [
    "team_hours.date",
    "team_hours.person",
    "team_hours.employer",
    "team_hours.clocked_in",
    "team_hours.clocked_out",
    "team_hours.worked_minutes",
    "team_hours.paid_minutes",
    "team_hours.note_still_clocked_in",
    "team_hours.note_not_clocked_out",
    "team_hours.note_needs_correction",
    "team_hours.note_corrected",
    "team_hours.total_worked",
    "team_hours.total_paid",
  ],
  "/reports/speed-to-lead": [
    "speed_to_lead.deals",
    "speed_to_lead.called",
    "speed_to_lead.median_business_minutes",
    "speed_to_lead.within_target_pct",
    "speed_to_lead.before_next_noon_pct",
    "speed_to_lead.open_not_called",
    "speed_to_lead.total_row",
    "speed_to_lead.open_list.waiting_business_minutes",
    "speed_to_lead.open_list.no_business_hours",
  ],
  "/reports/calls": [
    "calls.total",
    "calls.inbound",
    "calls.answered_inbound",
    "calls.outbound",
    "calls.avg_talk",
    "calls.talk_total",
    "calls.chart",
    "calls.outbound_connected",
    "calls.outbound_connected_share",
    "calls.outbound_talk",
    "calls.outbound_talk_avg",
    "calls.conversations",
    "calls.untagged_share",
    "calls.tag_bars",
    "calls.tags_by_group",
  ],
  "/reports/calls-per-agent": [
    "calls_per_agent.answered_inbound",
    "calls_per_agent.inbound_talk_avg",
    "calls_per_agent.outbound_calls",
    "calls_per_agent.connected_outbound",
    "calls_per_agent.outbound_talk_avg",
    "calls_per_agent.untagged",
    "calls_per_agent.conversations",
    "calls_per_agent.first_last_call",
    "calls_per_agent.not_linked_users",
    "calls_per_agent.total_row",
    "calls_per_agent.tag_split",
  ],
  "/reports/email": [
    "email.received",
    "email.logged_replies",
    "email.sent_agent",
    "email.sent_automated",
    "email.bounced_failed",
    "email.conversations_opened",
    "email.conversations_closed",
    "email.first_reply_median_business",
    "email.first_reply_median_elapsed",
    "email.first_reply_within_target_share",
    "email.first_reply_replied",
    "email.first_reply_no_hours",
    "email.time_to_close_median_business",
    "email.time_to_close_median_elapsed",
    "email.history_start",
    "email.waiting.waiting_since",
    "email.waiting.waited_business",
    "email.waiting.waited_elapsed",
    "email.waiting.total",
    "email.not_responding.last_email",
    "email.not_responding.days_since",
    "email.not_responding.owner",
    "email.not_responding.total",
  ],
  "/reports/email-per-agent": [
    "email_per_agent.sent",
    "email_per_agent.first_replies",
    "email_per_agent.median_first_reply",
    "email_per_agent.within_target_share",
    "email_per_agent.closed",
    "email_per_agent.sent_by_hour",
    "email_per_agent.not_linked",
    "email_per_agent.total",
  ],
  "/reports/follow-up": [
    "follow_up.leads_open_not_called",
    "follow_up.leads_past_target",
    "follow_up.tickets_at_risk",
    "follow_up.tickets_breached",
    "follow_up.tickets_without_owner",
    "follow_up.tasks_overdue",
    "follow_up.tasks_due_today",
    "follow_up.tasks_unmapped_owner",
    "follow_up.updated_ago",
    "follow_up.showing_of_total",
    "follow_up.leads.waiting_business_minutes",
    "follow_up.leads.age_bucket_business_days",
    "follow_up.leads.target_state",
    "follow_up.leads.last_call_days",
    "follow_up.tickets.open_business_minutes",
    "follow_up.tickets.response_time_minutes",
    "follow_up.tickets.sla_state",
    "follow_up.tickets.minutes_to_breach",
    "follow_up.tasks.due_state",
    "follow_up.tasks.callback_badge",
    "follow_up.per_person.open_leads",
    "follow_up.per_person.leads_past_target",
    "follow_up.per_person.open_tickets",
    "follow_up.per_person.tickets_at_risk_or_breached",
    "follow_up.per_person.tasks_overdue",
    "follow_up.per_person.tasks_due_today",
    "callbacks.week.callbacks",
    "callbacks.week.kept",
    "callbacks.week.not_kept",
    "callbacks.week.pending",
    "callbacks.week.kept_share",
    "callbacks.week.no_contact",
    "callbacks.week.no_due",
    "callbacks.per_person.callbacks",
    "callbacks.per_person.kept",
    "callbacks.per_person.not_kept",
    "callbacks.per_person.pending",
    "callbacks.per_person.kept_share",
    "callbacks.per_person.no_contact",
    "callbacks.per_person.unlinked_owners",
  ],
  "/reports/attempts": [
    "attempts.deals",
    "attempts.attempted_share",
    "attempts.per_deal",
    "attempts.reached_share",
    "attempts.median_speed_to_lead",
    "attempts.open_never_attempted",
    "attempts.without_outcome_share",
    "attempts.logged_without_aircall",
    "attempts.outcomes.deals",
    "attempts.outcomes.avg_attempts",
    "attempts.outcomes.median_attempts",
    "attempts.outcomes.median_speed",
    "attempts.outcomes.noon_share",
    "attempts.outcomes.reached_share",
    "attempts.outcomes.avg_talk_reached",
    "attempts.outcomes.not_decided",
    "attempts.win_rate_by_attempts",
    "attempts.win_rate_by_speed",
    "attempts.deals_by_attempts",
    "attempts.reached_per_attempt",
    "attempts.open_by_days_since_last",
    "attempts.groups",
    "attempts.list.total",
    "attempts.list.outcome",
    "attempts.list.attempts",
    "attempts.list.reached",
    "attempts.list.first_reached",
    "attempts.list.talk_in_contact",
    "attempts.list.speed_to_lead",
    "attempts.list.last_attempt",
    "attempts.list.days_since",
    "attempts.deal.n",
    "attempts.deal.started_at",
    "attempts.deal.answered",
    "attempts.deal.talk_seconds",
    "attempts.deal.reached_by",
    "attempts.deal.outcome_label",
    "attempts.deal.agent_name",
  ],
  "/reports/attempts-per-agent": [
    "attempts_per_agent.deals",
    "attempts_per_agent.attempts",
    "attempts_per_agent.avg_attempts",
    "attempts_per_agent.reached_share",
    "attempts_per_agent.median_speed",
    "attempts_per_agent.talk_reached",
    "attempts_per_agent.open_never_attempted",
    "attempts_per_agent.unlinked_owners",
    "attempts_per_agent.total",
  ],
  "/reports/funnel": [
    "funnel.created",
    "funnel.won",
    "funnel.lost",
    "funnel.win_rate",
    "funnel.median_days_to_won",
    "funnel.median_days_to_lost",
    "funnel.stage.entered",
    "funnel.stage.still_there",
    "funnel.stage.moved_on",
    "funnel.stage.median_days",
    "funnel.stage.reached_won",
    "funnel.stage.entered_previous",
    "funnel.by_pipeline",
    "lost_reasons.lost",
    "lost_reasons.with_reason_share",
    "lost_reasons.no_reason",
    "lost_reasons.data_quality",
    "lost_reasons.by_reason",
    "lost_reasons.no_reason_row",
    "lost_reasons.data_quality_reasons",
    "lost_reasons.by_market",
    "lost_reasons.by_source",
    "lost_reasons.by_period",
    "lost_reasons.list",
    "deals_per_person.won",
    "deals_per_person.lost",
    "deals_per_person.amounts",
    "deals_per_person.won_without_amount",
    "deals_per_person.unlinked_owners",
    "deals_per_person.total",
  ],
  "/reports/cancellations": [
    "cancellations.requests",
    "cancellations.open",
    "cancellations.closed",
    "cancellations.median_days_to_close",
    "cancellations.by_market",
    "cancellations.by_reason",
    "cancellations.by_period",
    "cancellations.list",
  ],
  "/reports/forms": [
    "forms.submissions",
    "forms.forms_with_submissions",
    "forms.contact_found_share",
    "forms.without_market",
    "forms.submissions_per_group",
    "forms.per_form_market.submissions",
    "forms.per_form_market.previous",
    "forms.per_form_market.change",
    "forms.per_form_market.resolved_share",
    "forms.by_category",
    "forms.by_market",
    "forms.resolution_split",
    "forms.answers",
    "forms.history_start",
  ],
  "/reports/intake": [
    "intake.form_submissions",
    "intake.deals_created",
    "intake.deals_closed",
    "intake.tickets_created",
    "intake.tickets_closed",
    "intake.calls_in",
    "intake.calls_out",
    "intake.tagged_calls",
    "intake.new_customers",
    "intake.first_orders",
    "intake.repeat_orders",
    "intake.renewals",
    "intake.total_row",
    "intake.volume_bar",
    "intake.start_date_note",
    "intake.no_telephony_state",
    "intake.no_shop_state",
  ],
  "/reports/inbound": [
    "inbound.offered",
    "inbound.answered",
    "inbound.unanswered_share",
    "inbound.service_level",
    "inbound.avg_answer",
    "inbound.waiting",
    "inbound.reason_count",
    "inbound.bar",
    "inbound.total",
  ],
  "/reports/first-orders": [
    "first_orders.total",
    "first_orders.call_center",
    "first_orders.self_service",
    "first_orders.days_median",
    "first_orders.repeats",
    "first_orders.renewals",
    "first_orders.not_first",
    "first_orders.no_contact",
    "first_orders.chart",
    "first_orders.by_level",
    "first_orders.amounts.orders",
    "first_orders.amounts.amount",
    "first_orders.amounts.call_center_amount",
    "first_orders.amounts.self_service_amount",
    "first_orders.list.deal",
    "first_orders.list.market",
    "first_orders.list.ordered_at",
    "first_orders.list.level",
    "first_orders.list.evidence",
    "first_orders.list.days",
    "first_orders.list.amount",
    "first_orders.list.shown",
    "first_orders.history_start",
    "first_orders.phone_start",
  ],
  "/reports/orders-per-person": [
    "orders_per_person.orders",
    "orders_per_person.per_level",
    "orders_per_person.days_median",
    "orders_per_person.not_linked",
  ],
  "/reports/data-quality": [
    "data_quality.deal_without_contact",
    "data_quality.deal_contact_incomplete",
    "data_quality.market_not_in_catalog",
    "data_quality.owner_without_person",
    "data_quality.telephony_user_without_person",
    "data_quality.crm_call_without_contact",
    "data_quality.telephony_call_unlinked",
    "data_quality.commerce_unmatched",
    "data_quality.commerce_ambiguous",
    "data_quality.writeback_parked",
    "data_quality.contact_slots_full",
    "data_quality.contact_country_differs",
    "data_quality.customer_in_two_stores",
    "data_quality.pipeline_unreviewed",
    "data_quality.form_without_market",
    "data_quality.contact_country_fallback",
    "data_quality.ticket_no_owner",
    "data_quality.ticket_no_market",
    "data_quality.crm_task_owner_unlinked",
    "data_quality.form_answer_not_in_options",
    "data_quality.outbox_pending",
  ],
  "/messages/send": [
    "messages.sent.recipients",
    "messages.sent.read",
    "messages.sent.acknowledged",
    "messages.sent.median_time_to_read",
    "messages.sent.withdrawn_state",
    "messages.compose.sent_to",
  ],
  "/roster/planner/print": [
    "roster.print.planned_minutes_per_person",
    "roster.print.headcount_per_day",
  ],
  "/configuration/health": [
    "health.app.probe_round_trip_ms",
    "health.heartbeat.age",
    "health.sources.state",
    "health.sources.last_event",
    "health.sources.events_24h",
    "health.sources.events_waiting",
    "health.sources.events_parked",
    "health.sources.last_read_back",
    "health.sources.last_failure",
    "health.jobs.last_run",
    "health.jobs.duration",
    "health.jobs.outcome",
    "health.jobs.counts",
    "health.jobs.runs_24h",
    "health.outbox.actions",
    "health.outbox.oldest",
    "health.outbox.next_attempt",
  ],
  "/messages": [
    "messages.unread_count",
    "messages.inbox.unread_shown",
  ],
  "/day": [
    "my_day.worked_today",
    "my_day.started_at",
    "my_day.current_status",
    "my_day.status_since",
    "my_day.ended_at",
  ],
  "/hours": [
    "my_hours.date",
    "my_hours.start",
    "my_hours.end",
    "my_hours.pauses",
    "my_hours.duration",
    "my_hours.total_duration",
    "my_hours.total_pauses",
  ],
  "/schedule": [
    "my_schedule.planned_total",
    "my_schedule.day_state",
  ],
  "/me/follow-up": [
    "my_follow_up.leads",
    "my_follow_up.tickets",
    "my_follow_up.tasks",
  ],
};

/** Every registered key, flat, for the uniqueness and coverage checks */
export function registeredKeys(): string[] {
  return Object.values(PAGE_METRIC_KEYS).flat();
}

/** The filters of the catalog page; empty strings mean "all" */
export interface MetricsFilter {
  q: string;
  page: string;
  surface: string;
  owner: string;
  status: string;
}

/** The facts of one card the filter looks at (the card carries them as data attributes) */
export interface MetricCardFacts {
  key: string;
  page: string;
  surface: string;
  owners: readonly string[];
  statuses: readonly string[];
  text: string;
}

export function cardFacts(e: Pick<MetricEntry, "key" | "page" | "surface" | "sources" | "status" | "tile" | "definition">): MetricCardFacts {
  return {
    key: e.key,
    page: e.page,
    surface: e.surface,
    owners: [...new Set(e.sources.map((s) => s.owner))],
    statuses: e.status,
    text: `${e.key} ${e.tile ?? ""} ${e.definition}`.toLowerCase(),
  };
}

/** True when the card stays visible under these filters; the words of q must all occur */
export function matchesFilter(card: MetricCardFacts, f: MetricsFilter): boolean {
  if (f.page && card.page !== f.page) return false;
  if (f.surface && card.surface !== f.surface) return false;
  if (f.owner && !card.owners.includes(f.owner)) return false;
  if (f.status && !card.statuses.includes(f.status)) return false;
  const words = f.q.toLowerCase().split(/\s+/).filter(Boolean);
  return words.every((w) => card.text.includes(w));
}

/** The filter choices the catalog offers, each list in first-seen order */
export function filterChoices(entries: readonly Pick<MetricEntry, "page" | "surface" | "sources" | "status">[]): {
  pages: string[]; surfaces: string[]; owners: string[]; statuses: string[];
} {
  const seen = { pages: new Set<string>(), surfaces: new Set<string>(), owners: new Set<string>(), statuses: new Set<string>() };
  for (const e of entries) {
    seen.pages.add(e.page);
    seen.surfaces.add(e.surface);
    for (const s of e.sources) seen.owners.add(s.owner);
    for (const s of e.status) seen.statuses.add(s);
  }
  return {
    pages: [...seen.pages], surfaces: [...seen.surfaces], owners: [...seen.owners], statuses: [...seen.statuses],
  };
}

/** The entries grouped by page in the catalog's order, for the page's sections */
export function entriesByPage<T extends Pick<MetricEntry, "page">>(entries: readonly T[]): { page: string; entries: T[] }[] {
  const out: { page: string; entries: T[] }[] = [];
  for (const e of entries) {
    const last = out.find((g) => g.page === e.page);
    if (last) last.entries.push(e);
    else out.push({ page: e.page, entries: [e] });
  }
  return out;
}
