# Repository conventions

## Ruby structure

Use one primary class or module per file. Separate independent classes and substantial helpers.
Keep small nested helpers, record types, and closely related child classes with their owner when this improves cohesion.
Keep related error classes in `errors.rb`. Test fixture classes can remain with their tests.
Preserve namespaces, visibility, and existing require entry points when moving definitions.

## Method names

Use `!` for validation and assertion methods that raise on failure, including checks that return the validated value.
Use descriptive names such as `integer!`, `ensure_width!`, and `validate_slot!`.
Ordinary parsers, readers, writers, and constructors need no `!` merely because they can raise.
Preserve conventional mutation names such as `merge!`.

Use `?` for boolean queries, with names that describe the condition being tested.
Commands such as `remove` and `cancel_publication` can return boolean results without `?`.
Readers that consume input and commands that change state are not queries.
Keep generated `Struct` field accessors, Ruby operators, and Minitest assertion naming conventions.
