# Change Principles

These principles apply to all changes in this repository.

## 1. Validate Changes With Real Evidence

Every meaningful change should be validated with evidence that matches the change.

- Frontend/UI changes: validate through browser usage, screenshots, Playwright, or clear manual browser instructions.
- Backend/API changes: validate with direct calls such as `curl`, API clients, integration tests, or command output.
- Data/worker changes: validate with realistic data setup and observable results.
- Use the tool that makes sense for the change.
- If the right validation tool is missing, ask to build or add that tool instead of guessing.

## 2. Test Changes Properly

Tests should prove behavior and prevent regressions.

- Add meaningful tests for user-visible, API-visible, or business-critical behavior.
- Do not add useless tests for simple configuration files, passive data classes, or trivial implementation details.
- Prefer integration/behavior tests when they provide stronger confidence than isolated unit tests.
- Keep tests readable and maintainable.

## 3. Keep Code Concise, Modular, and Readable

Code should be easy to understand and change.

- Prefer clear names and simple control flow.
- Keep implementations concise without hiding important behavior.
- When duplication appears, modularize or extract helpers/components.
- Follow good engineering principles without overengineering.
- Optimize for future maintainers being able to understand the code quickly.
