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
    shortcutsHint: "Keys 1 and 2 switch pages, L logs out",
    version: "Version",
    testData: "Test data: nothing you do here is saved",
  },
  myDay: {
    title: "My day",
    workingSince: "Working since",
    workedToday: "Worked today",
    endWorkday: "End workday",
    dayEnded: "Your workday has ended",
    comingNext: "The workday clock and your hours arrive in the next release",
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
    shortcutsHint: "Toets 1 en 2 wisselen van pagina, L logt uit",
    version: "Versie",
    testData: "Testgegevens: niets wat je hier doet wordt bewaard",
  },
  myDay: {
    title: "Mijn dag",
    workingSince: "Aan het werk sinds",
    workedToday: "Vandaag gewerkt",
    endWorkday: "Werkdag beëindigen",
    dayEnded: "Je werkdag is beëindigd",
    comingNext: "De werkdagklok en je uren komen in de volgende release",
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
