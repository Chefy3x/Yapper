//! API-key storage — port of `Yapper/Services/Keychain.swift`.
//!
//! macOS Keychain ⇄ Windows Credential Manager. The `keyring` crate wraps both
//! behind one API, so this file is the same shape as the Swift original and can
//! be exercised during Mac-side development against the real Keychain.
//!
//! The keys never touch a config file, the repo, or an environment variable on
//! either platform.

const SERVICE: &str = "app.yapper.windows";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Account {
    ElevenLabsKey,
    OpenAIKey,
}

impl Account {
    fn as_str(self) -> &'static str {
        match self {
            Account::ElevenLabsKey => "elevenlabs.api.key",
            Account::OpenAIKey => "openai.api.key",
        }
    }
}

fn entry(account: Account) -> Result<keyring::Entry, keyring::Error> {
    keyring::Entry::new(SERVICE, account.as_str())
}

pub fn set(value: &str, account: Account) -> bool {
    entry(account).and_then(|e| e.set_password(value)).is_ok()
}

pub fn get(account: Account) -> Option<String> {
    let value = entry(account).ok()?.get_password().ok()?;
    (!value.is_empty()).then_some(value)
}

pub fn remove(account: Account) -> bool {
    entry(account).and_then(|e| e.delete_credential()).is_ok()
}

/// Whether a provider is configured at all — the check the coordinator makes
/// before choosing a streaming engine over the native voice.
pub fn has_key(account: Account) -> bool {
    get(account).is_some()
}
