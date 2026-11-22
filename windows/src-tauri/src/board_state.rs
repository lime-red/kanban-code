use crate::activity_detector::{ActivityState, ActivityTracker};
use crate::assign_column::update_card_column;
use crate::card_reconciler::reconcile;
use crate::coordination_store::{CoordinationStore, Link};
use crate::git_worktree;
use crate::session_discovery::{Session, SessionDiscovery};
use crate::settings_store::SettingsStore;
use anyhow::Result;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CardDto {
    pub id: String,
    pub link: Link,
    pub session: Option<Session>,
    pub activity_state: Option<String>,
    pub display_title: String,
    pub project_name: Option<String>,
    pub relative_time: String,
    pub show_spinner: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct BoardStateDto {
    pub cards: Vec<CardDto>,
    pub last_refresh: Option<DateTime<Utc>>,
}

/// Suppress duplicate notifications for the same card if a previous one
/// fired within this window. Mirrors NotificationDeduplicator.swift on Mac
/// (62 s — slightly longer than the activity poll cadence so a flapping
/// session that ping-pongs activelyWorking↔needsAttention can't spam).
const NOTIFICATION_DEDUP_SECS: i64 = 62;

#[derive(Debug, Default)]
pub struct BoardState {
    pub cards: Vec<CardDto>,
    pub last_refresh: Option<DateTime<Utc>>,
    /// Previous activity state per card id, used to detect transitions
    prev_activity: HashMap<String, String>,
    /// Wall-clock time we last emitted a notification for each card, used to
    /// suppress repeats within NOTIFICATION_DEDUP_SECS.
    last_notified_at: HashMap<String, DateTime<Utc>>,
    /// Tracks JSONL mtime changes across polls to detect active vs stopped
    activity_tracker: ActivityTracker,
}

impl BoardState {
    /// Refresh board state: discover sessions, load links, reconcile, assign columns.
    pub async fn refresh(
        &mut self,
        discovery: &SessionDiscovery,
        store: &CoordinationStore,
        _settings: &SettingsStore,
    ) -> Result<()> {
        let sessions = discovery.discover_sessions().await?;
        let existing_links = store.read_links().await?;

        // --- Reconcile: merge sessions into links without duplicates ---
        let mut all_links = reconcile(existing_links.clone(), sessions.clone());

        // --- Backfill worktree paths from `git worktree list` ---
        // Cards with a branch but a missing/empty path get matched against
        // the project's actual worktrees so the UI can show the real on-disk
        // location and the cleanup-from-Done flow has something to operate on.
        backfill_worktree_paths(&mut all_links).await;

        // --- Detect activity once per session, cache results ---
        let sessions_by_id: HashMap<String, Session> =
            sessions.into_iter().map(|s| (s.id.clone(), s)).collect();

        let mut activity_map: HashMap<String, ActivityState> = HashMap::new();
        for link in &all_links {
            if let Some(path) = link
                .session_link
                .as_ref()
                .and_then(|sl| sl.session_path.as_deref())
            {
                activity_map
                    .entry(link.id.clone())
                    .or_insert_with(|| self.activity_tracker.detect(path));
            }
        }

        // --- Assign columns using cached activity ---
        for link in &mut all_links {
            let activity = activity_map.get(&link.id);
            let has_worktree = link
                .worktree_link
                .as_ref()
                .map(|wl| !wl.path.is_empty())
                .unwrap_or(false);

            update_card_column(link, activity, has_worktree);
        }

        // --- Persist onto the current file, not onto the snapshot read above ---
        // Discovery and reconciling take a while; a card created, edited or
        // deleted meanwhile must survive this write (as macOS modifyLinks).
        // The board then shows the merged links, so it isn't a refresh behind.
        let refreshed = all_links.clone();
        if let Ok(merged) = store
            .modify_links(|fresh| {
                merge_refresh(&existing_links, refreshed, fresh);
                fresh.clone()
            })
            .await
        {
            all_links = merged;
        }

        // --- Build CardDtos using cached activity ---
        let mut cards = Vec::new();
        for link in &all_links {
            let session = link
                .session_link
                .as_ref()
                .and_then(|sl| sessions_by_id.get(&sl.session_id))
                .cloned();

            let activity = activity_map.get(&link.id);
            let activity_str = activity.map(ActivityState::as_str);

            let display_title = if let Some(name) = &link.name {
                if !name.is_empty() {
                    name.clone()
                } else {
                    link.display_title()
                }
            } else if let Some(s) = &session {
                s.display_title()
            } else {
                link.display_title()
            };

            let project_name = link
                .project_path
                .as_deref()
                .or_else(|| session.as_ref().and_then(|s| s.project_path.as_deref()))
                .and_then(|p| std::path::Path::new(p).file_name())
                .and_then(|n| n.to_str())
                .map(|s| s.to_string());

            let relative_time =
                format_relative_time(link.last_activity.unwrap_or(link.updated_at));

            let show_spinner = activity == Some(&ActivityState::ActivelyWorking)
                || link.is_launching == Some(true);

            cards.push(CardDto {
                id: link.id.clone(),
                link: link.clone(),
                session,
                activity_state: activity_str.map(|s| s.to_string()),
                display_title,
                project_name,
                relative_time,
                show_spinner,
            });
        }

        self.cards = cards;
        self.last_refresh = Some(Utc::now());
        Ok(())
    }

    pub fn to_dto(&self) -> BoardStateDto {
        BoardStateDto {
            cards: self.cards.clone(),
            last_refresh: self.last_refresh,
        }
    }

    /// Returns cards that just transitioned to NeedsAttention (Claude finished a turn).
    /// Should be called after `refresh()` to drive OS notifications.
    ///
    /// Applies a per-card dedup window: a card that already fired a
    /// notification within the last `NOTIFICATION_DEDUP_SECS` is skipped.
    /// This prevents a flapping activity detector from spamming the user
    /// when the JSONL mtime briefly flips back-and-forth.
    pub fn drain_notification_candidates(&mut self) -> Vec<CardDto> {
        let now = Utc::now();
        let mut notify = Vec::new();
        let mut new_states: HashMap<String, String> = HashMap::new();

        for card in &self.cards {
            let current = card.activity_state.as_deref().unwrap_or("").to_string();
            new_states.insert(card.id.clone(), current.clone());

            let prev = self.prev_activity.get(&card.id).map(|s| s.as_str()).unwrap_or("");

            // Notify when Claude just stopped working and needs the user's attention
            if current == "needsAttention" && prev == "activelyWorking" {
                let last = self.last_notified_at.get(&card.id).copied();
                let suppressed = last
                    .map(|t| (now - t).num_seconds() < NOTIFICATION_DEDUP_SECS)
                    .unwrap_or(false);
                if !suppressed {
                    self.last_notified_at.insert(card.id.clone(), now);
                    notify.push(card.clone());
                }
            }
        }

        self.prev_activity = new_states;
        notify
    }
}

/// Match each card's worktree_link.branch against the actual git worktrees
/// in its project, filling in `worktree_link.path` when missing. Skips cards
/// without a project_path or without a branch; bails on git failures (no
/// worktree info isn't fatal). Worktrees are listed at most once per
/// project_root so the polling loop doesn't fork git N times for one repo.
/// Apply one refresh's result to the links as they are now.
///
/// `snapshot` is what the refresh read, `refreshed` what it made of it, and
/// `current` the store's links at write time, changed in place:
/// - a card unchanged since the snapshot takes the refreshed version (its
///   column, newly linked session, ...), or goes if the refresh dropped it;
/// - a card changed since the snapshot keeps its current version; the next
///   refresh reconciles it;
/// - cards the refresh discovered are added, unless they were in the snapshot
///   and have been deleted since;
/// - cards created since the snapshot stay.
fn merge_refresh(snapshot: &[Link], refreshed: Vec<Link>, current: &mut Vec<Link>) {
    let as_json = |l: &Link| serde_json::to_value(l).ok();
    let snap: HashMap<&str, Option<serde_json::Value>> =
        snapshot.iter().map(|l| (l.id.as_str(), as_json(l))).collect();
    let mut refreshed_by_id: HashMap<String, Link> =
        refreshed.iter().map(|l| (l.id.clone(), l.clone())).collect();

    current.retain_mut(|cur| {
        let Some(before) = snap.get(cur.id.as_str()) else {
            return true; // created since the snapshot
        };
        let unchanged = before.is_some() && *before == as_json(cur);
        match refreshed_by_id.remove(&cur.id) {
            Some(r) if unchanged => {
                *cur = r;
                true
            }
            Some(_) => true,
            None => !unchanged, // the refresh dropped it
        }
    });

    for link in refreshed {
        if !snap.contains_key(link.id.as_str()) && refreshed_by_id.contains_key(&link.id) {
            current.push(link);
        }
    }
}

async fn backfill_worktree_paths(links: &mut [Link]) {
    use std::collections::HashMap;

    let project_roots: std::collections::HashSet<String> = links
        .iter()
        .filter_map(|l| l.project_path.clone())
        .collect();

    let mut worktrees_by_root: HashMap<String, Vec<git_worktree::Worktree>> = HashMap::new();
    for root in project_roots {
        if let Ok(list) = git_worktree::list_worktrees(&root).await {
            worktrees_by_root.insert(root, list);
        }
    }

    for link in links.iter_mut() {
        let Some(project) = link.project_path.as_deref() else { continue };
        let Some(wt) = link.worktree_link.as_mut() else { continue };
        let Some(branch) = wt.branch.as_deref() else { continue };
        if !wt.path.is_empty() {
            continue;
        }
        if let Some(matches) = worktrees_by_root.get(project) {
            if let Some(found) = matches.iter().find(|w| w.branch.as_deref() == Some(branch)) {
                wt.path = found.path.clone();
            }
        }
    }
}

fn format_relative_time(date: DateTime<Utc>) -> String {
    format_relative_time_at(date, chrono::Local::now())
}

/// Relative time by the local calendar, not 24-hour buckets: something from
/// 23:50 last night reads "yesterday" at 00:10, and something from 08:00
/// yesterday is not "15h ago" at 23:00 today. Port of the macOS
/// `formatRelativeTime` fix.
fn format_relative_time_at(date: DateTime<Utc>, now: chrono::DateTime<chrono::Local>) -> String {
    let secs = (now.with_timezone(&Utc) - date).num_seconds();
    if secs < 60 {
        return "just now".to_string();
    }
    if secs < 3600 {
        return format!("{}m ago", secs / 60);
    }
    let then_day = date.with_timezone(&chrono::Local).date_naive();
    let today = now.date_naive();
    let days = (today - then_day).num_days();
    if days <= 0 {
        return format!("{}h ago", (secs / 3600).max(1));
    }
    if days == 1 {
        return "yesterday".to_string();
    }
    if days < 30 {
        return format!("{}d ago", days);
    }
    format!("{}mo ago", days / 30)
}

#[cfg(test)]
mod relative_time_tests {
    use super::*;
    use chrono::{Local, TimeZone};

    fn local(y: i32, mo: u32, d: u32, h: u32, mi: u32) -> chrono::DateTime<Local> {
        Local.with_ymd_and_hms(y, mo, d, h, mi, 0).single().unwrap()
    }

    #[test]
    fn just_after_midnight_last_night_is_yesterday() {
        let now = local(2026, 11, 15, 0, 10);
        let then = local(2026, 11, 14, 22, 50).with_timezone(&Utc);
        assert_eq!(format_relative_time_at(then, now), "yesterday");
    }

    #[test]
    fn same_day_is_hours() {
        let now = local(2026, 11, 15, 23, 0);
        let then = local(2026, 11, 15, 8, 0).with_timezone(&Utc);
        assert_eq!(format_relative_time_at(then, now), "15h ago");
    }

    #[test]
    fn two_calendar_days_back_is_2d_even_under_48h() {
        let now = local(2026, 11, 15, 1, 0);
        let then = local(2026, 11, 13, 23, 0).with_timezone(&Utc);
        assert_eq!(format_relative_time_at(then, now), "2d ago");
    }

    #[test]
    fn future_and_recent_are_just_now() {
        let now = local(2026, 11, 15, 12, 0);
        assert_eq!(format_relative_time_at(local(2026, 11, 15, 12, 5).with_timezone(&Utc), now), "just now");
        assert_eq!(format_relative_time_at(local(2026, 11, 15, 11, 30).with_timezone(&Utc), now), "30m ago");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn card(id: &str, column: &str) -> Link {
        let mut l: Link = serde_json::from_value(serde_json::json!({
            "id": id,
            "column": column,
            "source": "manual",
            "createdAt": "2026-11-22T00:00:00Z",
            "updatedAt": "2026-11-22T00:00:00Z",
        }))
        .expect("minimal link");
        l.name = Some(id.to_string());
        l
    }

    fn ids(links: &[Link]) -> Vec<(String, String)> {
        links.iter().map(|l| (l.id.clone(), l.column.clone())).collect()
    }

    #[test]
    fn refresh_keeps_a_card_created_while_it_ran() {
        let snapshot = vec![card("a", "backlog")];
        let refreshed = vec![card("a", "waiting")];
        let mut current = vec![card("a", "backlog"), card("new", "backlog")];
        merge_refresh(&snapshot, refreshed, &mut current);
        assert_eq!(ids(&current), vec![("a".into(), "waiting".into()), ("new".into(), "backlog".into())]);
    }

    #[test]
    fn refresh_keeps_an_edit_made_while_it_ran() {
        let snapshot = vec![card("a", "backlog")];
        let refreshed = vec![card("a", "waiting")];
        let mut current = vec![card("a", "on_hold")];
        merge_refresh(&snapshot, refreshed, &mut current);
        assert_eq!(ids(&current), vec![("a".into(), "on_hold".into())]);
    }

    #[test]
    fn refresh_does_not_bring_back_a_card_deleted_while_it_ran() {
        let snapshot = vec![card("a", "backlog"), card("gone", "backlog")];
        let refreshed = vec![card("a", "backlog"), card("gone", "waiting")];
        let mut current = vec![card("a", "backlog")];
        merge_refresh(&snapshot, refreshed, &mut current);
        assert_eq!(ids(&current), vec![("a".into(), "backlog".into())]);
    }

    #[test]
    fn refresh_adds_discovered_cards_and_drops_ones_it_removed() {
        let snapshot = vec![card("a", "backlog"), card("dup", "waiting")];
        let refreshed = vec![card("a", "backlog"), card("found", "waiting")];
        let mut current = snapshot.clone();
        merge_refresh(&snapshot, refreshed, &mut current);
        assert_eq!(ids(&current), vec![("a".into(), "backlog".into()), ("found".into(), "waiting".into())]);
    }

    #[test]
    fn refresh_keeps_a_card_it_dropped_if_edited_meanwhile() {
        let snapshot = vec![card("dup", "waiting")];
        let mut current = vec![card("dup", "on_hold")];
        merge_refresh(&snapshot, vec![], &mut current);
        assert_eq!(ids(&current), vec![("dup".into(), "on_hold".into())]);
    }
}
