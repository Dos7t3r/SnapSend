# Branching and publication

The owner explicitly requested the first public GitHub repository and release. The initial snapshot bootstraps the new repository; there is no existing default-branch history or pull-request base to preserve.

After that initial publication, use short-lived `codex/` branches and open pull requests targeting `main`. Do not push changes directly to `main`, force-push, merge your own PR, or alter protections without the owner's instruction. Do not commit local signing settings, credentials, generated build output, or user photo archives.

A public release must describe actual validation, include separate browser-extension downloads, and exclude personal iOS provisioning profiles. CI and protection-policy changes require owner review; this initial release does not add either.
