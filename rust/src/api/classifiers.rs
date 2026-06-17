use std::collections::HashMap;

fn build_knowledge_base() -> HashMap<String, String> {
    let mut rules = HashMap::new();

    let data = [
        ("Work", vec![
            "call", "email", "meeting", "report", "teacher", "deadline", "project", "office", "boss",
            "colleague", "presentation", "slack", "zoom", "client", "invoice", "salary", "shift",
            "business", "manager", "task", "spreadsheet", "contract", "resume", "interview",
            "feedback", "workshop", "seminar", "linkedin", "strategy", "goal", "quarterly",
        ]),
        ("Shopping", vec![
            "buy", "eggs", "store", "grocery", "milk", "shop", "order", "amazon", "sale", "price",
            "cart", "checkout", "market", "delivery", "coupon", "wallet", "receipt", "purchase",
            "item", "stock", "mall", "list", "discount", "offer", "brand", "fashion",
            "clothing", "electronics", "supermarket", "retail",
        ]),
        ("Health", vec![
            "doctor", "gym", "meds", "workout", "water", "pill", "appointment", "dentist",
            "exercise", "diet", "medicine", "hospital", "clinic", "therapy", "yoga", "running",
            "pain", "checkup", "vitamins", "sleep", "health", "insurance", "pharmacy",
            "optometrist", "fever", "cough", "vaccine", "wellness", "fitness", "nutrition",
        ]),
        ("College", vec![
            "assignment", "lecture", "professor", "exam", "study", "library", "campus",
            "university", "course", "credits", "grade", "homework", "midterm", "final", "thesis",
            "scholarship", "dorm", "semester", "class", "tutor", "student", "degree", "diploma",
            "faculty", "tuition", "registration", "transcript", "major", "minor", "dean",
        ]),
        ("Social", vec![
            "friend", "party", "dinner", "lunch", "coffee", "meetup", "birthday", "wedding",
            "date", "hangout", "visit", "drinks", "club", "event", "celebration", "chat",
            "message", "invite", "gathering", "brunch", "movie", "concert", "festival", "holiday",
            "weekend", "trip", "travel", "flight", "hotel", "vacation",
        ]),
        ("Home", vec![
            "clean", "laundry", "dishes", "repair", "rent", "bills", "garden", "kitchen", "vacuum",
            "furniture", "maintenance", "mortgage", "utilities", "mop", "trash", "fixing",
            "decoration", "living", "bedroom", "bathroom", "plumber", "electrician", "roof",
            "painting", "renovation", "lease", "neighbor", "backyard", "garage",
        ]),
        ("Finance", vec![
            "bank", "money", "investment", "stock", "crypto", "tax", "budget", "savings",
            "loan", "credit", "debt", "interest", "wallet", "bitcoin", "ethereum",
            "trading", "broker", "portfolio", "retirement", "pension", "expense", "income",
        ]),
        // --- Coding / Project-themed categories ---
        ("UI/UX", vec![
            "button", "layout", "design", "color", "font", "icon", "animation", "css",
            "style", "theme", "responsive", "mobile", "desktop", "screen", "widget",
            "component", "page", "view", "navbar", "sidebar", "header", "footer",
            "modal", "dialog", "popup", "toast", "card", "grid", "flex", "padding",
            "margin", "border", "shadow", "gradient", "image", "logo", "typography",
            "hover", "click", "tap", "scroll", "slider", "dropdown", "input", "form",
            "checkbox", "radio", "toggle", "switch", "tab", "carousel", "figma",
            "sketch", "prototype", "wireframe", "mockup", "pixel", "ui", "ux",
            "accessibility", "a11y", "dark", "light", "palette", "spacing",
        ]),
        ("Backend", vec![
            "api", "endpoint", "server", "route", "controller", "middleware", "auth",
            "authentication", "authorization", "jwt", "token", "session", "cookie",
            "cors", "request", "response", "rest", "graphql", "grpc", "websocket",
            "socket", "http", "https", "ssl", "tls", "proxy", "load", "balancer",
            "cache", "redis", "queue", "worker", "cron", "job", "microservice",
            "lambda", "function", "handler", "service", "logic", "algorithm",
            "validation", "serialization", "parsing", "encryption", "hash",
            "logging", "error", "exception", "retry", "timeout", "rate", "limit",
            "webhook", "callback", "async", "sync", "thread", "process", "rust",
            "node", "python", "java", "golang", "express", "fastapi", "spring",
        ]),
        ("Database", vec![
            "database", "db", "sql", "nosql", "query", "table", "schema", "migration",
            "model", "orm", "relation", "index", "primary", "foreign", "key", "join",
            "select", "insert", "update", "delete", "transaction", "commit", "rollback",
            "postgres", "postgresql", "mysql", "sqlite", "mongo", "mongodb", "dynamo",
            "firestore", "supabase", "prisma", "sequelize", "typeorm", "knex",
            "seed", "backup", "restore", "replica", "shard", "partition", "column",
            "row", "record", "collection", "document", "blob", "storage",
        ]),
        ("Testing", vec![
            "test", "testing", "unit", "integration", "e2e", "coverage", "assert",
            "expect", "mock", "stub", "spy", "fixture", "snapshot", "regression",
            "benchmark", "performance", "profiling", "lint", "linting", "format",
            "ci", "continuous", "jest", "mocha", "pytest", "junit", "selenium",
            "cypress", "playwright", "debug", "debugger", "breakpoint", "log",
            "trace", "bug", "fix", "issue", "ticket", "qa", "quality",
        ]),
        ("DevOps", vec![
            "deploy", "deployment", "docker", "container", "kubernetes", "k8s", "helm",
            "terraform", "ansible", "jenkins", "github", "gitlab", "bitbucket",
            "pipeline", "cicd", "build", "release", "staging", "production", "dev",
            "environment", "env", "config", "configuration", "secret", "variable",
            "monitoring", "metrics", "alert", "grafana", "prometheus", "datadog",
            "aws", "gcp", "azure", "cloud", "cdn", "dns", "domain", "ssl",
            "nginx", "apache", "traefik", "ingress", "scaling", "autoscale",
            "rollback", "canary", "blue", "green", "infra", "infrastructure",
        ]),
        ("Icebox", vec![
            "later", "maybe", "someday", "future", "v2", "v3", "backlog", "wishlist",
            "nice", "idea", "brainstorm", "explore", "research", "experiment",
            "prototype", "spike", "optional", "low", "priority", "defer", "postpone",
            "parking", "shelf", "archive", "dream", "stretch", "bonus",
        ]),
    ];

    for (category, words) in data {
        for word in words {
            rules.insert(word.to_string(), category.to_string());
        }
    }

    rules
}

#[flutter_rust_bridge::frb(sync)]
pub fn classify_intent(context: &str) -> String {
    // 1. Check for explicit dynamic tags like @Name or #Topic anywhere in the text (handles JSON-encoded values too)
    if let Some(pos) = context.find(|c| c == '@' || c == '#') {
        let tag_content = &context[pos + 1..];
        let clean_tag: String = tag_content
            .chars()
            .take_while(|c| c.is_alphanumeric() || *c == '_')
            .collect();
        if !clean_tag.is_empty() {
            let mut c = clean_tag.chars();
            return match c.next() {
                None => String::new(),
                Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
            };
        }
    }

    let words: Vec<&str> = context.split_whitespace().collect();

    // 2. Fallback to keyword knowledge base
    let knowledge_base = build_knowledge_base();
    let mut scoreboard: HashMap<String, i32> = HashMap::new();

    for word in &words {
        let clean_word = word.to_lowercase();
        let clean_word = clean_word.trim_matches(|c: char| !c.is_alphanumeric());
        
        if let Some(category) = knowledge_base.get(clean_word) {
            let count = scoreboard.entry(category.clone()).or_insert(0);
            *count += 1;
        }
    }

    scoreboard
        .into_iter()
        .max_by_key(|&(_, count)| count)
        .map(|(category, _)| category)
        .unwrap_or_else(|| "General".to_string())
}