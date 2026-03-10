# Example PRD: Build a Simple Task Tracker CLI

This is a multi-phase PRD for testing the Tarvos orchestration system.

## Phase 1: Project Setup

- Initialize a new Node.js project with `npm init -y`
- Create the directory structure:
  ```
  src/
  ├── index.js       # CLI entry point
  ├── store.js       # JSON file-based storage
  └── display.js     # Terminal output formatting
  ```
- Set up the `bin` field in package.json pointing to `src/index.js`
- Add a shebang line (`#!/usr/bin/env node`) to index.js
- Verify the project structure is correct

## Phase 2: Implement Core Functionality

- **store.js**: Implement CRUD operations for tasks stored in a `tasks.json` file:
  - `loadTasks()` - read tasks from file (return empty array if file missing)
  - `saveTasks(tasks)` - write tasks array to file
  - `addTask(title)` - add a new task with `{ id, title, done: false, createdAt }`
  - `completeTask(id)` - mark a task as done
  - `deleteTask(id)` - remove a task
  - `listTasks()` - return all tasks
- **display.js**: Format tasks for terminal display:
  - `formatTask(task)` - format a single task as `[x] #1: Task title` or `[ ] #1: Task title`
  - `formatTaskList(tasks)` - format all tasks with a header and count

## Phase 3: CLI Interface and Testing

- **index.js**: Parse command-line arguments and route to appropriate functions:
  - `task-tracker add "Buy groceries"` - add a task
  - `task-tracker list` - show all tasks
  - `task-tracker done 1` - mark task #1 as complete
  - `task-tracker delete 1` - delete task #1
  - `task-tracker help` - show usage information
- Add basic error handling (invalid commands, missing arguments)
- Test all commands manually and verify they work
- Commit everything to git with a meaningful commit message
