use crate::activity_detector::ActivityState;
use crate::coordination_store::Link;

/// Port of AssignColumn.swift.
/// Determines which Kanban column a link belongs in based on its current state.
/// Respects manual overrides — if the user dragged a card, keep it there.
pub fn assign_column(
    link: &Link,
    activity: Option<&ActivityState>,
    has_worktree: bool,
) -> String {
    // Manual On Hold override is unconditionally sticky: the user explicitly
    // paused this card until they choose to resume, start, or move it.
    if link.manual_overrides.column && link.column == "on_hold" {
        return "on_hold".to_string();
    }

    let has_pr = !link.pr_links.is_empty();
    let all_prs_done = !link.pr_links.is_empty()
        && link
            .pr_links
            .iter()
            .all(|p| matches!(p.status.as_deref(), Some("MERGED") | Some("CLOSED")));

    // Actively working always wins — even overrides archive
    if activity == Some(&ActivityState::ActivelyWorking) {
        return "in_progress".to_string();
    }

    // Archived
    if link.manually_archived {
        return "all_sessions".to_string();
    }

    // All PRs merged/closed → done
    if all_prs_done {
        return "done".to_string();
    }

    // User manually dragged → respect it
    if link.manual_overrides.column {
        return link.column.clone();
    }

    // PR exists + session not actively working → in review
    if has_pr {
        if let Some(state) = activity {
            match state {
                ActivityState::NeedsAttention
                | ActivityState::IdleWaiting
                | ActivityState::Ended
                | ActivityState::Stale => return "in_review".to_string(),
                _ => {}
            }
        }
    }

    // Activity-based
    if let Some(state) = activity {
        match state {
            ActivityState::ActivelyWorking => return "in_progress".to_string(),
            ActivityState::NeedsAttention => return "requires_attention".to_string(),
            ActivityState::IdleWaiting => return "requires_attention".to_string(),
            ActivityState::Ended => {
                if has_worktree {
                    return "requires_attention".to_string();
                }
                // fall through to recency check
            }
            ActivityState::Stale => {
                // fall through to recency check
            }
        }
    }

    // GitHub issue without a session → backlog
    if link.source == "github_issue" && link.session_link.is_none() {
        return "backlog".to_string();
    }

    // Manual task without a session → backlog
    if link.source == "manual" && link.session_link.is_none() {
        return "backlog".to_string();
    }

    // Has an active worktree → at least waiting
    if has_worktree {
        return "requires_attention".to_string();
    }

    // Recently active (within 24h) → waiting
    if let Some(last) = link.last_activity {
        let hours = (chrono::Utc::now() - last).num_seconds() as f64 / 3600.0;
        if hours < 24.0 {
            return "requires_attention".to_string();
        }
    }

    // Default
    "all_sessions".to_string()
}

/// Apply column assignment to a link in-place, clearing archive flag if
/// the session just became actively working.
pub fn update_card_column(link: &mut Link, activity: Option<&ActivityState>, has_worktree: bool) {
    let new_col = assign_column(link, activity, has_worktree);

    // If an archived card becomes actively working, unarchive it
    if link.manually_archived && new_col == "in_progress" {
        link.manually_archived = false;
    }

    if new_col != link.column {
        link.column = new_col;
        link.updated_at = chrono::Utc::now();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::coordination_store::{ManualOverrides, PrLink};
    use chrono::Utc;

    fn sample_link(column: &str, override_column: bool) -> Link {
        let now = Utc::now();
        Link {
            id: "card-1".into(),
            name: Some("Test".into()),
            project_path: None,
            column: column.into(),
            created_at: now,
            updated_at: now,
            last_activity: None,
            manual_overrides: ManualOverrides {
                column: override_column,
                ..Default::default()
            },
            manually_archived: false,
            on_hold_until: None,
            on_hold_notified_at: None,
            source: "manual".into(),
            prompt_body: None,
            prompt_image_paths: None,
            session_link: None,
            worktree_link: None,
            pr_links: vec![],
            issue_link: None,
            discovered_branches: None,
            is_remote: false,
            is_launching: None,
            queued_prompts: None,
            sort_order: None,
            pinned_at: None,
            pinned_sort_order: None,
            assistant_id: "claude".into(),
            last_opened_at: None,
            api_service_id: None,
            browser_tabs: None,
            card_runtime: None,
        }
    }

    #[test]
    fn manual_on_hold_is_sticky_across_activity_and_done_prs() {
        let mut link = sample_link("on_hold", true);
        link.pr_links.push(PrLink {
            number: 42,
            url: None,
            status: Some("MERGED".into()),
            title: None,
            body: None,
            approval_count: None,
            unresolved_threads: None,
            merge_state_status: None,
            review_decision: None,
            check_runs: vec![],
        });

        assert_eq!(assign_column(&link, Some(&ActivityState::ActivelyWorking), true), "on_hold");
        assert_eq!(assign_column(&link, Some(&ActivityState::NeedsAttention), true), "on_hold");
        assert_eq!(assign_column(&link, None, false), "on_hold");
    }
}
