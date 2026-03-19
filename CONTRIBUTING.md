# Contributing to ConnectionPool

Thank you for your interest in contributing to ConnectionPool. This guide will help you get started.

## Getting Started

1. Fork the repository.
2. Clone your fork locally.
3. Create a new branch from `main` for your work.

## Development

- **Xcode**: 16.0 or later
- **Platforms**: iOS 17+, macOS 14+
- **Language**: Swift 6
- **Dependencies**: None. ConnectionPool has no external dependencies.

Open `Package.swift` in Xcode to build and test the library.

## Code Style

- Follow existing patterns and conventions in the codebase.
- Use Swift 6 strict concurrency throughout.
- Prefer the `@MainActor` + `nonisolated` delegate pattern for cross-isolation communication.
- Keep types and methods focused on a single responsibility.

## Pull Requests

- Keep pull requests focused: one feature or fix per PR.
- Describe *why* the change is needed, not just *what* changed.
- Ensure all tests pass and there are no new compiler warnings before submitting.
- Fill out the pull request template completely.

## Issues

- Use the provided issue templates when opening a new issue.
- Search existing issues before creating a new one to avoid duplicates.

## License

By contributing to ConnectionPool, you agree that your contributions will be licensed under the [MIT License](LICENSE).
