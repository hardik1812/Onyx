pub fn run_audit(project_text: String) -> String {
    let mut findings = Vec::new();
    let lower = project_text.to_lowercase();

    // Rule 1: Binary files in database (Critical)
    if lower.contains("blob") || (lower.contains("sqlite") && (lower.contains("image") || lower.contains("pdf") || lower.contains("file") || lower.contains("video"))) {
        findings.push(format!(
            r#"{{"severity": "Critical", "message": "Writing binary files/large blobs directly into SQLite database. Database size will bloat instantly, fragmentation will destroy performance. Store file paths on disk and keep references in DB.", "source": "SQLite Binary Storage Check"}}"#
        ));
    }

    // Rule 2: Tokio blocking (Warning)
    if lower.contains("blocking") && (lower.contains("tokio") || lower.contains("async") || lower.contains("event loop")) {
        findings.push(format!(
            r#"{{"severity": "Warning", "message": "Executing blocking CPU-bound tasks inside async executor threads without spawn_blocking. This will starve the scheduler and cause random latency spikes.", "source": "Tokio Blocking Call"}}"#
        ));
    }

    // Rule 3: Memory limits (Warning)
    if lower.contains("cache") && !lower.contains("evict") && !lower.contains("ttl") && !lower.contains("lru") {
        findings.push(format!(
            r#"{{"severity": "Warning", "message": "In-memory cache implemented without any eviction policy (TTL, LRU, or maximum size). Memory usage will grow unboundedly under load, leading to OOM crashes.", "source": "Cache Eviction Policy"}}"#
        ));
    }

    // Rule 4: Plaintext secrets (Critical)
    if lower.contains("password") || lower.contains("api_key") || lower.contains("apikey") || lower.contains("private_key") || lower.contains("secret") {
        findings.push(format!(
            r#"{{"severity": "Critical", "message": "Storing raw passwords, secrets, or API keys in code or plain text. These will leak into version control or decompiled client binaries. Use secure vaults or env variables.", "source": "Plaintext Secrets"}}"#
        ));
    }

    // Rule 5: Scope creep (ScopeCreep)
    if lower.contains("v2") || lower.contains("v3") || lower.contains("later") || lower.contains("cloud sync") || lower.contains("kubernetes") || lower.contains("docker") || lower.contains("microservice") {
        findings.push(format!(
            r#"{{"severity": "ScopeCreep", "message": "Planning cloud sync, kubernetes, or microservice architecture in early v2. Focus on validating the core product and local SQLite flow first.", "source": "Early Over-Engineering"}}"#
        ));
    }

    // Rule 6: Shared Mutex contention (Warning)
    if lower.contains("mutex") || lower.contains("arc") || lower.contains("lock") {
        findings.push(format!(
            r#"{{"severity": "Warning", "message": "Heavy reliance on global locks (Arc<Mutex<T>>) across threads. Expect thread contention bottlenecks and potential deadlocks under load.", "source": "Lock Contention"}}"#
        ));
    }

    // Rule 7: Sync Network Request (Critical)
    if lower.contains("synchronous") && (lower.contains("network") || lower.contains("request") || lower.contains("http")) {
        findings.push(format!(
            r#"{{"severity": "Critical", "message": "Synchronous network requests on worker threads block operations. Use non-blocking async network runtimes.", "source": "Sync Network IO Check"}}"#
        ));
    }

    // If no findings, always inject some senior developer cynicism
    if findings.is_empty() {
        findings.push(format!(
            r#"{{"severity": "Warning", "message": "No critical architectural warning flags. You either have an empty project canvas or are over-simplifying your backend specs. A senior dev is always suspicious.", "source": "Architecture Summary"}}"#
        ));
    }

    format!("[{}]", findings.join(","))
}
