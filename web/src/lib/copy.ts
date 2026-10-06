/**
 * All user-facing text, in one place, per language.
 * Rules (Pulse4all-Style.md section 4): sentence case, no all-caps, no
 * exclamation marks, no period after a title, no backend mechanics in copy.
 * The copy verifier checks these rules against this file.
 */
export type Locale = "en" | "nl";

/** Deep string shape; keeps the type structural so both languages share it */
type Deep<T> = { [K in keyof T]: T[K] extends string ? string : Deep<T[K]> };

const en = {
  app: {
    name: "Workspace",
    tagline: "Pulse4all contact center",
  },
  nav: {
    myDay: "My day",
    myHours: "My hours",
    logOut: "Log out",
  },
  shell: {
    signedInAs: "Signed in as",
    shortcutsHint: "Keys 1 and 2 switch pages, S picks a status on My day, L logs out, Esc closes a dialog",
    version: "Version",
    testData: "Test data: nothing you do here is saved",
  },
  myDay: {
    title: "My day",
    working: "Working",
    workingSince: "since",
    workedToday: "Worked today",
    endWorkday: "End workday",
    confirmTitle: "End your workday",
    confirmBody: "Your clock stops now. A new workday starts when you log in tomorrow.",
    confirmYes: "End workday",
    confirmNo: "Keep working",
    dayEnded: "Your workday has ended",
    dayEndedBody: "Thanks for today. Log out when you leave, or close this tab.",
    endedAt: "Ended at",
    statusLabel: "Status",
    statusFailed: "Your status could not be changed. Try again.",
    startedAt: "Started at",
  },
  myHours: {
    title: "My hours",
    ownHoursOnly: "These are your own hours. Your supervisor sees the same figures.",
    today: "Today",
    week: "This week",
    month: "This month",
    custom: "Custom range",
    from: "From",
    to: "To",
    show: "Show",
    date: "Date",
    start: "Start",
    end: "End",
    duration: "Duration",
    total: "Total",
    stillWorking: "still working",
    empty: "No hours in this period yet",
    invalidRange: "Choose a start date on or before the end date",
  },
  logOut: {
    title: "Log out",
    body: "This ends your workday and signs you out of the Workspace.",
    bodyDayEnded: "Your workday has already ended. This signs you out of the Workspace.",
    confirm: "Log out",
    cancel: "Stay",
    doneTitle: "You are logged out",
    doneBody: "You can close this tab. Logging in again tomorrow starts your next workday.",
    doneBodyToday: "Your workday has ended for today. You can close this tab.",
  },
  noAccess: {
    title: "No access yet",
    body: "Your Pulse4all account is recognised, but it is not set up for the Workspace yet.",
    next: "Ask your supervisor to add you. You can close this tab.",
  },
  desktopOnly: {
    title: "The Workspace needs a wider screen",
    body: "Open it on a desktop or laptop with a window of at least 1280 pixels wide.",
  },
} satisfies Record<string, Record<string, string>>;

export type Copy = Deep<typeof en>;

const nl: Copy = {
  app: {
    name: "Workspace",
    tagline: "Pulse4all contactcenter",
  },
  nav: {
    myDay: "Mijn dag",
    myHours: "Mijn uren",
    logOut: "Uitloggen",
  },
  shell: {
    signedInAs: "Ingelogd als",
    shortcutsHint: "Toets 1 en 2 wisselen van pagina, S kiest een status op Mijn dag, L logt uit, Esc sluit een venster",
    version: "Versie",
    testData: "Testgegevens: niets wat je hier doet wordt bewaard",
  },
  myDay: {
    title: "Mijn dag",
    working: "Aan het werk",
    workingSince: "sinds",
    workedToday: "Vandaag gewerkt",
    endWorkday: "Werkdag beëindigen",
    confirmTitle: "Je werkdag beëindigen",
    confirmBody: "Je klok stopt nu. Een nieuwe werkdag begint als je morgen inlogt.",
    confirmYes: "Werkdag beëindigen",
    confirmNo: "Doorwerken",
    dayEnded: "Je werkdag is beëindigd",
    dayEndedBody: "Bedankt voor vandaag. Log uit als je weggaat, of sluit dit tabblad.",
    endedAt: "Beëindigd om",
    statusLabel: "Status",
    statusFailed: "Je status kon niet worden gewijzigd. Probeer het opnieuw.",
    startedAt: "Gestart om",
  },
  myHours: {
    title: "Mijn uren",
    ownHoursOnly: "Dit zijn je eigen uren. Je supervisor ziet dezelfde cijfers.",
    today: "Vandaag",
    week: "Deze week",
    month: "Deze maand",
    custom: "Eigen periode",
    from: "Van",
    to: "Tot en met",
    show: "Toon",
    date: "Datum",
    start: "Start",
    end: "Einde",
    duration: "Duur",
    total: "Totaal",
    stillWorking: "nog aan het werk",
    empty: "Nog geen uren in deze periode",
    invalidRange: "Kies een startdatum op of voor de einddatum",
  },
  logOut: {
    title: "Uitloggen",
    body: "Dit beëindigt je werkdag en logt je uit bij de Workspace.",
    bodyDayEnded: "Je werkdag is al beëindigd. Dit logt je uit bij de Workspace.",
    confirm: "Uitloggen",
    cancel: "Blijven",
    doneTitle: "Je bent uitgelogd",
    doneBody: "Je kunt dit tabblad sluiten. Morgen opnieuw inloggen start je volgende werkdag.",
    doneBodyToday: "Je werkdag is beëindigd voor vandaag. Je kunt dit tabblad sluiten.",
  },
  noAccess: {
    title: "Nog geen toegang",
    body: "Je Pulse4all-account is herkend, maar is nog niet ingericht voor de Workspace.",
    next: "Vraag je supervisor om je toe te voegen. Je kunt dit tabblad sluiten.",
  },
  desktopOnly: {
    title: "De Workspace heeft een breder scherm nodig",
    body: "Open hem op een desktop of laptop met een venster van minstens 1280 pixels breed.",
  },
};

export const copy: Record<Locale, Copy> = { en, nl };
export function t(locale: Locale): Copy {
  return copy[locale];
}
