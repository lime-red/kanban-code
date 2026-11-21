use crate::coordination_store::{Link, SessionLink, WorktreeLink};
use crate::ksuid;
use crate::session_discovery::Session;
use std::collections::HashMap;

/// Port of CardReconciler.swift.
///
/// Matches discovered sessions/worktrees to existing cards.
/// Prevents duplicate card creation (the "triplication bug").
pub fn reconcile(existing: Vec<Link>, sessions: Vec<Session>) -> Vec<Link> {
    let mut links_by_id: HashMap<String, Link> =
        existing.into_iter().map(|l| (l.id.clone(), l)).collect();

    // Build reverse indexes
    let mut card_id_by_session_id: HashMap<String, String> = HashMap::new();
    let mut cards_by_branch: HashMap<String, Vec<String>> = HashMap::new();

    for link in links_by_id.values() {
        if let Some(sl) = &link.session_link {
            card_id_by_session_id.insert(sl.session_id.clone(), link.id.clone());
        }
        if let Some(wl) = &link.worktree_link {
            if let Some(branch) = &wl.branch {
                cards_by_branch
                    .entry(branch.clone())
                    .or_default()
                    .push(link.id.clone());
            }
        }
        if let Some(branches) = &link.discovered_branches {
            for branch in branches {
                let ids = cards_by_branch.entry(branch.clone()).or_default();
                if !ids.contains(&link.id) {
                    ids.push(link.id.clone());
                }
            }
        }
    }

    let session_modified_by_id: HashMap<&str, chrono::DateTime<chrono::Utc>> =
        sessions.iter().map(|s| (s.id.as_str(), s.modified_time)).collect();

    // A. Match each session to an existing card (or create a new one)
    for session in &sessions {
        let card_id = find_card_for_session(
            session,
            &card_id_by_session_id,
            &cards_by_branch,
            &links_by_id,
        );

        if let Some(card_id) = card_id {
            if let Some(link) = links_by_id.get_mut(&card_id) {
                if link.manually_archived {
                    continue;
                }
                if link.session_link.is_none() {
                    link.session_link = Some(SessionLink {
                        session_id: session.id.clone(),
                        session_path: session.jsonl_path.clone(),
                        session_number: None,
                    });
                    link.updated_at = chrono::Utc::now();
                    card_id_by_session_id.insert(session.id.clone(), card_id.clone());
                } else if link
                    .session_link
                    .as_ref()
                    .map(|sl| sl.session_id.as_str())
                    == Some(session.id.as_str())
                {
                    // Same session — update path in case file moved
                    if let Some(sl) = &mut link.session_link {
                        sl.session_path = session.jsonl_path.clone();
                    }
                } else if link.column != "backlog"
                    && link.column != "on_hold"
                    && link.column != "all_sessions"
                    && link.column != "done"
                {
                    // A newer session started in the card's project (e.g. via
                    // `/clear` or restarting Claude in the card's terminal).
                    // Switch `session_link` to the newer session so activity
                    // tracking follows the active conversation.
                    let existing_modified = link
                        .session_link
                        .as_ref()
                        .and_then(|sl| session_modified_by_id.get(sl.session_id.as_str()).copied())
                        .or(link.last_activity);
                    let is_newer = existing_modified
                        .map(|em| (session.modified_time - em).num_milliseconds() > 1000)
                        .unwrap_or(true);
                    if is_newer {
                        link.session_link = Some(SessionLink {
                            session_id: session.id.clone(),
                            session_path: session.jsonl_path.clone(),
                            session_number: None,
                        });
                        link.updated_at = chrono::Utc::now();
                        card_id_by_session_id.insert(session.id.clone(), card_id.clone());
                    }
                }

                let is_primary_session = link
                    .session_link
                    .as_ref()
                    .map(|sl| sl.session_id.as_str())
                    == Some(session.id.as_str());
                if is_primary_session || link.last_activity.is_none() {
                    link.last_activity = Some(session.modified_time);
                }
                if link.project_path.is_none() {
                    link.project_path = session.project_path.clone();
                }
                if link.prompt_body.is_none() {
                    link.prompt_body = session.first_prompt.clone();
                }
            }
        } else {
            // Truly new session — create a card
            let new_link = new_discovered_link(session);
            card_id_by_session_id.insert(session.id.clone(), new_link.id.clone());
            // Index its branch
            if let Some(branch) = &session.git_branch {
                let base = strip_refs_heads(branch);
                if base != "main" && base != "master" {
                    cards_by_branch
                        .entry(base.to_string())
                        .or_default()
                        .push(new_link.id.clone());
                }
            }
            links_by_id.insert(new_link.id.clone(), new_link);
        }
    }

    // A2. Index session gitBranch into cards_by_branch
    for session in &sessions {
        if let Some(branch) = &session.git_branch {
            let base = strip_refs_heads(branch);
            if base == "main" || base == "master" {
                continue;
            }
            if let Some(card_id) = card_id_by_session_id.get(&session.id) {
                let ids = cards_by_branch.entry(base.to_string()).or_default();
                if !ids.contains(card_id) {
                    ids.push(card_id.clone());
                }
            }
        }
    }

    // B2. Dedup: absorb orphan worktree-only cards into real cards on the same branch
    let branches: Vec<String> = cards_by_branch
        .keys()
        .filter(|b| cards_by_branch[*b].len() > 1)
        .cloned()
        .collect();

    for branch in branches {
        let card_ids = cards_by_branch[&branch].clone();
        let orphan_ids: Vec<String> = card_ids
            .iter()
            .filter(|id| {
                links_by_id
                    .get(*id)
                    .map(|l| l.session_link.is_none() && l.source != "manual" && l.name.is_none())
                    .unwrap_or(false)
            })
            .cloned()
            .collect();

        if orphan_ids.is_empty() {
            continue;
        }

        let real_ids: Vec<String> = card_ids
            .iter()
            .filter(|id| !orphan_ids.contains(id))
            .cloned()
            .collect();

        let keeper_id = real_ids.first().or(orphan_ids.first()).cloned().unwrap();

        for orphan_id in &orphan_ids {
            if *orphan_id == keeper_id {
                continue;
            }
            if let Some(orphan) = links_by_id.remove(orphan_id) {
                if let Some(keeper) = links_by_id.get_mut(&keeper_id) {
                    if keeper.worktree_link.is_none() {
                        keeper.worktree_link = orphan.worktree_link;
                    }
                }
            }
        }

        let live_ids: Vec<String> = card_ids
            .into_iter()
            .filter(|id| !orphan_ids.contains(id) || *id == keeper_id)
            .collect();
        cards_by_branch.insert(branch, live_ids);
    }

    // Collect remaining links preserving order (newest last_activity first)
    let mut result: Vec<Link> = links_by_id.into_values().collect();
    result.sort_by(|a, b| {
        let ta = a.last_activity.unwrap_or(a.updated_at);
        let tb = b.last_activity.unwrap_or(b.updated_at);
        tb.cmp(&ta)
    });
    result
}

/// How long a launched card waits for its first session (Rule 3).
const PENDING_LAUNCH_WINDOW_MINUTES: i64 = 30;

/// The session was last written between shortly before the card's latest
/// launch and the end of its wait window.
fn started_within_launch_window(session: &Session, link: &Link) -> bool {
    let since_launch = session.modified_time - link.updated_at;
    since_launch.num_seconds() >= -120
        && since_launch.num_minutes() <= PENDING_LAUNCH_WINDOW_MINUTES
}

fn find_card_for_session(
    session: &Session,
    card_id_by_session_id: &HashMap<String, String>,
    cards_by_branch: &HashMap<String, Vec<String>>,
    links_by_id: &HashMap<String, Link>,
) -> Option<String> {
    // 1. Exact sessionId match
    if let Some(id) = card_id_by_session_id.get(&session.id) {
        return Some(id.clone());
    }

    // 2. Branch match (session.gitBranch matches a card's worktreeLink.branch)
    if let Some(branch) = &session.git_branch {
        let base = strip_refs_heads(branch);
        if base != "main" && base != "master" {
            if let Some(ids) = cards_by_branch.get(base) {
                // Prefer cards without a session yet, same project
                let same_project: Vec<_> = ids
                    .iter()
                    .filter(|id| {
                        links_by_id
                            .get(*id)
                            .map(|l| project_matches(session, l))
                            .unwrap_or(false)
                    })
                    .collect();

                let pending = same_project
                    .iter()
                    .find(|id| {
                        links_by_id
                            .get(**id)
                            .map(|l| l.session_link.is_none())
                            .unwrap_or(false)
                    })
                    .cloned();

                if let Some(id) = pending.or(same_project.first().copied()) {
                    return Some(id.clone());
                }
            }
        }
    }

    // 3. Launched card in same project still waiting for its first session
    //    (e.g. a manual/issue card whose terminal just started Claude without a
    //    worktree branch). Only cards whose terminal was started count: picking
    //    a runtime is what launches one, and Windows never sets `is_launching`.
    //    Without that gate any parked card with no session would absorb the next
    //    session in its project, including one `/clear` starts in another card.
    //    The wait is also time-boxed: macOS drops a dead launch when its tmux
    //    session goes away, but Windows has no such signal, so a launch whose
    //    Claude never wrote a session (stuck at the trust prompt, drawer
    //    closed) would otherwise claim a session run by hand days later.
    //    Launching from the drawer refreshes `updated_at`, which restarts it.
    if session.project_path.is_some() {
        let best_pending = links_by_id
            .values()
            .filter(|l| {
                !l.manually_archived
                    && l.session_link.is_none()
                    && l.card_runtime.is_some()
                    && l.column != "on_hold"
                    && same_project(session, l)
                    && started_within_launch_window(session, l)
            })
            .max_by(|a, b| {
                let pa = prompt_matches(a, session);
                let pb = prompt_matches(b, session);
                pa.cmp(&pb)
                    .then_with(|| a.updated_at.cmp(&b.updated_at))
                    .then_with(|| a.id.cmp(&b.id))
            });
        if let Some(link) = best_pending {
            return Some(link.id.clone());
        }
    }

    // 4. Launched, active card in the same project that already has a session
    //    (e.g. `/clear` or restarting Claude in the card's terminal). The caller
    //    makes the new session primary only when it is newer; an older one, such
    //    as the conversation `/clear` just replaced, stays with the card instead
    //    of turning up as a card of its own (as on macOS). Parked, held, archived
    //    and done cards never absorb live work.
    if session.project_path.is_some() {
        let best_active = links_by_id
            .values()
            .filter(|l| {
                !l.manually_archived
                    && l.session_link.is_some()
                    && l.card_runtime.is_some()
                    && l.column != "backlog"
                    && l.column != "on_hold"
                    && l.column != "all_sessions"
                    && l.column != "done"
                    && same_project(session, l)
            })
            .max_by(|a, b| {
                let ta = a.last_activity.unwrap_or(a.updated_at);
                let tb = b.last_activity.unwrap_or(b.updated_at);
                ta.cmp(&tb).then_with(|| a.id.cmp(&b.id))
            });
        if let Some(link) = best_active {
            return Some(link.id.clone());
        }
    }

    None
}

fn prompt_matches(link: &Link, session: &Session) -> bool {
    let Some(p) = link
        .prompt_body
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    else {
        return false;
    };
    let Some(fp) = session
        .first_prompt
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    else {
        return false;
    };
    p == fp || fp.contains(p) || p.contains(fp)
}

fn project_matches(session: &Session, link: &Link) -> bool {
    let Some(session_path) = &session.project_path else {
        return true;
    };
    let Some(link_path) = &link.project_path else {
        return true;
    };
    // Compare with `/` separators: on Windows the transcript's cwd is
    // `C:\repo\.claude\worktrees\x`, which never starts with `C:\repo/`.
    let session_path = session_path.replace('\\', "/");
    let link_path = link_path.replace('\\', "/");
    let link_path = link_path.trim_end_matches('/');
    session_path == link_path || session_path.starts_with(&format!("{}/", link_path))
}

/// Stricter than `project_matches`, for the rules that match on project
/// alone: the session must run in the card's own folder or in one of its
/// `.claude/worktrees/` folders (as macOS's `isWorktreeUnder`). Any deeper
/// folder would let a card for a parent folder, such as the home folder,
/// absorb every session beneath it. Both paths must be known. Windows paths
/// compare without regard to case.
fn same_project(session: &Session, link: &Link) -> bool {
    let (Some(session_path), Some(link_path)) = (&session.project_path, &link.project_path) else {
        return false;
    };
    let norm = |p: &str| p.replace('\\', "/").trim_end_matches('/').to_ascii_lowercase();
    let (session_path, link_path) = (norm(session_path), norm(link_path));
    session_path == link_path
        || session_path.starts_with(&format!("{link_path}/.claude/worktrees/"))
}

fn strip_refs_heads(branch: &str) -> &str {
    branch.strip_prefix("refs/heads/").unwrap_or(branch)
}

fn new_discovered_link(session: &Session) -> Link {
    let now = chrono::Utc::now();
    let id = ksuid::generate(Some("card"));
    Link {
        id,
        name: session.name.clone(),
        project_path: session.project_path.clone(),
        column: "all_sessions".to_string(),
        created_at: session.modified_time,
        updated_at: now,
        last_activity: Some(session.modified_time),
        manual_overrides: Default::default(),
        manually_archived: false,
        source: "discovered".to_string(),
        prompt_body: session.first_prompt.clone(),
        prompt_image_paths: None,
        session_link: Some(SessionLink {
            session_id: session.id.clone(),
            session_path: session.jsonl_path.clone(),
            session_number: None,
        }),
        worktree_link: session.git_branch.as_ref().and_then(|b| {
            let base = strip_refs_heads(b);
            if base != "main" && base != "master" {
                Some(WorktreeLink {
                    path: String::new(),
                    branch: Some(base.to_string()),
                })
            } else {
                None
            }
        }),
        pr_links: vec![],
        issue_link: None,
        discovered_branches: None,
        is_remote: false,
        is_launching: None,
        queued_prompts: None,
        sort_order: None,
        pinned_at: None,
        pinned_sort_order: None,
        assistant_id: "claude".to_string(),
        last_opened_at: None,
        api_service_id: None,
        browser_tabs: None,
        card_runtime: None,
    }
}

#[cfg(test)]
mod project_match_tests {
    use super::*;
    use crate::settings_store::CardRuntime;

    fn session(path: &str) -> Session {
        Session {
            id: "s".into(),
            name: None,
            first_prompt: None,
            project_path: Some(path.into()),
            git_branch: None,
            message_count: 1,
            modified_time: chrono::Utc::now(),
            jsonl_path: None,
        }
    }

    fn link(path: &str) -> Link {
        let mut l = new_discovered_link(&session(path));
        l.project_path = Some(path.into());
        l
    }

    #[test]
    fn windows_worktree_matches_its_project() {
        assert!(project_matches(&session(r"C:\repo\.claude\worktrees\feat"), &link(r"C:\repo")));
        assert!(project_matches(&session(r"C:\repo"), &link(r"C:\repo\")));
    }

    #[test]
    fn sibling_prefix_does_not_match() {
        assert!(!project_matches(&session(r"C:\repo-two"), &link(r"C:\repo")));
        assert!(!project_matches(&session("/x/repo-two"), &link("/x/repo")));
        assert!(project_matches(&session("/x/repo/sub"), &link("/x/repo")));
    }

    #[test]
    fn replaces_older_session_in_same_project_when_newer_session_starts() {
        let t1 = chrono::Utc::now() - chrono::Duration::minutes(10);
        let t2 = chrono::Utc::now();

        let mut existing = link(r"C:\repo");
        existing.id = "card-1".into();
        existing.column = "requires_attention".into();
        existing.card_runtime = Some(CardRuntime::Windows);
        existing.last_activity = Some(t1);
        existing.session_link = Some(SessionLink {
            session_id: "old-sess".into(),
            session_path: Some(r"C:\old.jsonl".into()),
            session_number: None,
        });

        let mut new_sess = session(r"C:\repo");
        new_sess.id = "new-sess".into();
        new_sess.modified_time = t2;
        new_sess.jsonl_path = Some(r"C:\new.jsonl".into());

        let result = reconcile(vec![existing], vec![new_sess]);
        assert_eq!(result.len(), 1);
        let updated = &result[0];
        assert_eq!(updated.id, "card-1");
        assert_eq!(
            updated.session_link.as_ref().map(|s| s.session_id.as_str()),
            Some("new-sess")
        );
        assert_eq!(
            updated
                .session_link
                .as_ref()
                .and_then(|s| s.session_path.as_deref()),
            Some(r"C:\new.jsonl")
        );
        assert_eq!(updated.last_activity, Some(t2));
    }

    #[test]
    fn does_not_replace_session_on_backlog_or_on_hold_card() {
        let t1 = chrono::Utc::now() - chrono::Duration::minutes(10);
        let t2 = chrono::Utc::now();

        for parked_col in ["backlog", "on_hold"] {
            let mut parked = link(r"C:\repo");
            parked.id = format!("card-{parked_col}");
            parked.column = parked_col.into();
            parked.last_activity = Some(t1);
            parked.session_link = Some(SessionLink {
                session_id: "old-sess".into(),
                session_path: Some(r"C:\old.jsonl".into()),
                session_number: None,
            });

            let mut new_sess = session(r"C:\repo");
            new_sess.id = "new-sess".into();
            new_sess.modified_time = t2;
            new_sess.jsonl_path = Some(r"C:\new.jsonl".into());

            let result = reconcile(vec![parked], vec![new_sess]);
            assert_eq!(result.len(), 2, "parked card in {parked_col} must keep its own session");
            let kept = result.iter().find(|c| c.id == format!("card-{parked_col}")).unwrap();
            assert_eq!(
                kept.session_link.as_ref().map(|s| s.session_id.as_str()),
                Some("old-sess")
            );
        }
    }

    #[test]
    fn links_pending_manual_card_in_same_project() {
        let now = chrono::Utc::now();
        let mut pending = link(r"C:\repo");
        pending.id = "card-pending".into();
        pending.source = "manual".into();
        pending.column = "backlog".into();
        pending.session_link = None;
        pending.prompt_body = Some("Implement on hold column".into());
        pending.card_runtime = Some(CardRuntime::Windows);
        pending.updated_at = now - chrono::Duration::seconds(30);

        let mut sess = session(r"C:\repo");
        sess.id = "fresh-sess".into();
        sess.first_prompt = Some("Implement on hold column".into());
        sess.modified_time = now;
        sess.jsonl_path = Some(r"C:\fresh.jsonl".into());

        let result = reconcile(vec![pending], vec![sess]);
        assert_eq!(result.len(), 1);
        let linked = &result[0];
        assert_eq!(linked.id, "card-pending");
        assert_eq!(
            linked.session_link.as_ref().map(|s| s.session_id.as_str()),
            Some("fresh-sess")
        );
    }

    /// Found on the Windows test VM: `/clear` in a running card's terminal
    /// starts a new session, and it went to an unlaunched On Hold card in the
    /// same project instead of replacing the running card's session.
    #[test]
    fn clear_replaces_running_card_session_instead_of_filling_unlaunched_cards() {
        let now = chrono::Utc::now();

        let mut running = link(r"C:\repo");
        running.id = "card-running".into();
        running.source = "manual".into();
        running.column = "requires_attention".into();
        running.card_runtime = Some(CardRuntime::Windows);
        running.last_activity = Some(now - chrono::Duration::minutes(2));
        running.session_link = Some(SessionLink {
            session_id: "before-clear".into(),
            session_path: Some(r"C:\before.jsonl".into()),
            session_number: None,
        });

        let mut cards = vec![running];
        for col in ["on_hold", "backlog"] {
            let mut parked = link(r"C:\repo");
            parked.id = format!("card-{col}");
            parked.source = "manual".into();
            parked.column = col.into();
            parked.session_link = None;
            parked.updated_at = now - chrono::Duration::seconds(30);
            cards.push(parked);
        }

        let mut after_clear = session(r"C:\repo");
        after_clear.id = "after-clear".into();
        after_clear.modified_time = now;
        after_clear.jsonl_path = Some(r"C:\after.jsonl".into());

        let result = reconcile(cards, vec![after_clear]);
        let sid = |id: &str| {
            result
                .iter()
                .find(|c| c.id == id)
                .and_then(|c| c.session_link.as_ref())
                .map(|s| s.session_id.clone())
        };
        assert_eq!(sid("card-running").as_deref(), Some("after-clear"));
        assert_eq!(sid("card-on_hold"), None);
        assert_eq!(sid("card-backlog"), None);
        assert_eq!(result.len(), 3, "no extra card for the replacement session");
    }

    /// After `/clear` the card's previous conversation is no longer its
    /// primary session. It stays with the card rather than becoming a card
    /// of its own or being taken by another card.
    #[test]
    fn conversation_replaced_by_clear_stays_with_its_card() {
        let now = chrono::Utc::now();
        let mut running = link(r"C:\repo");
        running.id = "card-running".into();
        running.column = "requires_attention".into();
        running.card_runtime = Some(CardRuntime::Windows);
        running.last_activity = Some(now);
        running.session_link = Some(SessionLink {
            session_id: "after-clear".into(),
            session_path: Some(r"C:\after.jsonl".into()),
            session_number: None,
        });

        let mut current = session(r"C:\repo");
        current.id = "after-clear".into();
        current.modified_time = now;
        let mut before = session(r"C:\repo");
        before.id = "before-clear".into();
        before.modified_time = now - chrono::Duration::minutes(5);

        let result = reconcile(vec![running], vec![before, current]);
        assert_eq!(result.len(), 1, "no separate card for the replaced conversation");
        assert_eq!(
            result[0].session_link.as_ref().map(|s| s.session_id.as_str()),
            Some("after-clear")
        );
    }

    /// Found on the Windows test VM: a card for `C:\Users\dev` (from running
    /// Claude in the home folder) took a session from a project beneath it.
    #[test]
    fn parent_folder_card_does_not_absorb_sessions_from_subfolders() {
        let now = chrono::Utc::now();
        let mut home = link(r"C:\Users\dev");
        home.id = "card-home".into();
        home.column = "requires_attention".into();
        home.card_runtime = Some(CardRuntime::Windows);
        home.last_activity = Some(now - chrono::Duration::hours(1));
        home.session_link = Some(SessionLink {
            session_id: "home-sess".into(),
            session_path: None,
            session_number: None,
        });

        let mut project_sess = session(r"C:\Users\dev\code\kc_test space");
        project_sess.id = "project-sess".into();
        project_sess.modified_time = now;

        let result = reconcile(vec![home], vec![project_sess]);
        assert_eq!(result.len(), 2);
        let home = result.iter().find(|c| c.id == "card-home").unwrap();
        assert_eq!(home.session_link.as_ref().map(|s| s.session_id.as_str()), Some("home-sess"));
    }

    #[test]
    fn same_project_allows_only_the_folder_and_its_worktrees() {
        assert!(same_project(&session(r"C:\repo"), &link(r"C:\Repo\")));
        assert!(same_project(&session(r"C:\repo\.claude\worktrees\feat"), &link(r"C:\repo")));
        assert!(!same_project(&session(r"C:\repo\sub"), &link(r"C:\repo")));
        assert!(!same_project(&session(r"C:\repo-two"), &link(r"C:\repo")));
        let mut unknown = link(r"C:\repo");
        unknown.project_path = None;
        assert!(!same_project(&session(r"C:\repo"), &unknown));
    }

    #[test]
    fn launched_card_on_hold_does_not_take_new_session() {
        let now = chrono::Utc::now();
        let mut held = link(r"C:\repo");
        held.id = "card-held".into();
        held.column = "on_hold".into();
        held.card_runtime = Some(CardRuntime::Windows);
        held.session_link = None;
        held.updated_at = now - chrono::Duration::seconds(30);

        let mut sess = session(r"C:\repo");
        sess.id = "manual-sess".into();
        sess.modified_time = now;

        let result = reconcile(vec![held], vec![sess]);
        assert_eq!(result.len(), 2);
        let held = result.iter().find(|c| c.id == "card-held").unwrap();
        assert!(held.session_link.is_none());
    }

    #[test]
    fn stale_launch_does_not_take_a_much_later_session() {
        let now = chrono::Utc::now();
        let mut stale = link(r"C:\repo");
        stale.id = "card-stale".into();
        stale.column = "in_progress".into();
        stale.card_runtime = Some(CardRuntime::Windows);
        stale.session_link = None;
        stale.updated_at = now - chrono::Duration::days(2);

        let mut sess = session(r"C:\repo");
        sess.id = "manual-sess".into();
        sess.modified_time = now;

        let result = reconcile(vec![stale], vec![sess]);
        assert_eq!(result.len(), 2);
        let stale = result.iter().find(|c| c.id == "card-stale").unwrap();
        assert!(stale.session_link.is_none());
    }

    #[test]
    fn does_not_hijack_all_sessions_card_for_new_session() {
        let t1 = chrono::Utc::now() - chrono::Duration::days(3);
        let t2 = chrono::Utc::now();

        let mut old_card = link(r"C:\repo");
        old_card.id = "card-old".into();
        old_card.column = "all_sessions".into();
        old_card.last_activity = Some(t1);
        old_card.session_link = Some(SessionLink {
            session_id: "old-sess".into(),
            session_path: None,
            session_number: None,
        });

        let mut new_sess = session(r"C:\repo");
        new_sess.id = "new-sess".into();
        new_sess.modified_time = t2;

        let result = reconcile(vec![old_card], vec![new_sess]);
        assert_eq!(result.len(), 2);
    }
}
