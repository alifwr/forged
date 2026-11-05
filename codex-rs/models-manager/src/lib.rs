pub mod cache;
mod catalog;
pub mod collaboration_mode_presets;
pub(crate) mod config;
pub mod manager;
pub mod model_info;
pub mod model_presets;
mod originator;
pub mod test_support;

pub use catalog::CatalogModel;
pub use catalog::ModelOrigin;
pub use codex_protocol::auth::AuthMode;
pub use config::ModelsManagerConfig;
pub use originator::ModelCatalogOriginator;

/// Load the bundled model catalog shipped with `codex-models-manager`.
pub fn bundled_models_response()
-> std::result::Result<codex_protocol::openai_models::ModelsResponse, serde_json::Error> {
    serde_json::from_str(include_str!("../models.json"))
}

// The fork is built from an upstream development checkout with workspace version 0.0.0.
// Keep this catalog compatibility version aligned with a verified upstream release.
const FORGED_MODEL_CATALOG_COMPAT_VERSION: &str = "0.166.0";

/// Return the upstream-compatible client version used for catalog requests and cache identity.
pub fn client_version_to_whole() -> String {
    catalog_client_version(
        env!("CARGO_PKG_VERSION_MAJOR"),
        env!("CARGO_PKG_VERSION_MINOR"),
        env!("CARGO_PKG_VERSION_PATCH"),
    )
}

fn catalog_client_version(major: &str, minor: &str, patch: &str) -> String {
    if (major, minor, patch) == ("0", "0", "0") {
        FORGED_MODEL_CATALOG_COMPAT_VERSION.to_string()
    } else {
        format!("{major}.{minor}.{patch}")
    }
}

#[cfg(test)]
mod version_tests {
    use super::catalog_client_version;

    #[test]
    fn development_builds_use_the_verified_upstream_catalog_version() {
        assert_eq!(catalog_client_version("0", "0", "0"), "0.166.0");
        assert_eq!(catalog_client_version("0", "167", "1"), "0.167.1");
    }
}
