/** Mirrors Shared/MatchupLiveActivityAttributes.ContentState (JSON / APNs). */
export type ContentState = {
  myScore: number;
  oppScore: number;
  opponentName: string;
  week: number;
  statusLine: string;
  /** Legacy / mine — keep for older app builds. */
  playerLines: string[];
  /** Unix seconds — keep as number for APNs Codable interop. */
  lastUpdated: number;
  /** Unix seconds of the next scheduled backend sync. */
  nextSyncAt?: number;
  leagueName?: string;
  myTeamName?: string;
  providerLabel?: string;
  leagueLinkId?: string;
  leagueCount?: number;
  myPlayerLines?: string[];
  oppPlayerLines?: string[];
  nflGameLines?: string[];
};

export type Provider = "mfl" | "sleeper" | "espn";

export type ApnsEnvironment = "sandbox" | "production";

export type LiveSession = {
  id: string;
  pushToken: string;
  provider: Provider;
  leagueId: string;
  franchiseId: string;
  week: number;
  season: number;
  /** MFL host e.g. www64.myfantasyleague.com */
  host?: string;
  /** MFL MFL_USER_ID cookie — short-lived, only while Live Activity is active. */
  mflCookie?: string;
  /** ESPN private-league cookies (optional for public leagues). */
  espnS2?: string;
  espnSwid?: string;
  leagueName: string;
  myTeamName: string;
  providerLabel: string;
  opponentName?: string;
  /** Sleeper / ESPN playerId → display name for live lines */
  playerNames?: Record<string, string>;
  starterIds?: string[];
  /** Starters whose NFL game is currently in progress (from the iOS schedule annotate). */
  liveStarterIds?: string[];
  /** Opponent live fantasy lines from the last app sync (`Name  12.3`). */
  oppLivePlayerLines?: string[];
  /** Active NFL games from the last app sync (`KC @ LAC  12:34`). */
  nflGameLines?: string[];
  leagueLinkId?: string;
  leagueCount?: number;
  /** Hint from iOS; Worker may correct after a successful push. */
  apnsEnvironment?: ApnsEnvironment;
  createdAt: number;
  updatedAt: number;
};

export type RegisterBody = {
  activityId: string;
  pushToken: string;
  provider: Provider;
  leagueId: string;
  franchiseId: string;
  week: number;
  season: number;
  host?: string;
  mflCookie?: string;
  espnS2?: string;
  espnSwid?: string;
  leagueName: string;
  myTeamName: string;
  providerLabel: string;
  opponentName?: string;
  playerNames?: Record<string, string>;
  starterIds?: string[];
  liveStarterIds?: string[];
  oppLivePlayerLines?: string[];
  nflGameLines?: string[];
  leagueLinkId?: string;
  leagueCount?: number;
  /** "sandbox" (Xcode) | "production" (TestFlight / App Store) */
  apnsEnvironment?: ApnsEnvironment;
};

export type WatchedMatchup = {
  leagueId: string;
  week: number;
  touchedAt: number;
};

export type Env = {
  SESSIONS: KVNamespace;
  /** Shared public cache (schedule, state, matchups, metadata / ETags). */
  CACHE: KVNamespace;
  /** Large catalogs (Sleeper players, DynastyProcess CSV). */
  PUBLIC: R2Bucket;
  /** Shared secret the iOS app sends as X-Sideline-Key */
  REGISTER_SECRET: string;
  APNS_TEAM_ID: string;
  APNS_KEY_ID: string;
  /** Full .p8 PEM including BEGIN/END lines (escaped newlines in secret). */
  APNS_PRIVATE_KEY: string;
  APNS_BUNDLE_ID: string;
};
