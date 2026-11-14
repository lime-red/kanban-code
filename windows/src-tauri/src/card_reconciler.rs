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

    // 3. Pending card in same project (session_link is None, e.g. manual/issue
    //    card whose terminal just started a Claude session without a worktree branch).
    if session.project_path.is_some() {
        let best_pending = links_by_id
            .values()
            .filter(|l| {
                !l.manually_archived
                    && l.session_link.is_none()
                    && project_matches(session, l)
                    && (session.modified_time - l.updated_at).num_seconds() >= -120
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

    // 4. Active card in same project whose existing session is replaced by a
    //    newer session (e.g. `/clear` or restarting Claude in the card's terminal).
    //    Skip parked/held/archive/done cards so inactive cards don't absorb live work,
    //    and require the incoming session to be strictly newer than the card's activity.
    if session.project_path.is_some() {
        let best_active = links_by_id
            .values()
            .filter(|l| {
                !l.manually_archived
                    && l.session_link.is_some()
                    && l.column != "backlog"
                    && l.column != "on_hold"
                    && l.column != "all_sessions"
                    && l.column != "done"
                    && project_matches(session, l)
            })
            .filter(|l| {
                let card_time = l.last_activity.unwrap_or(l.updated_at);
                (session.modified_time - card_time).num_milliseconds() > 1000
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
