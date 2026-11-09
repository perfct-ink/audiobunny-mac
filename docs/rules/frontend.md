<!-- agent-rules:synced from agent-rules@1.4.0 (6f6a626) sha256:b86bd6ed864d. Edit agent-rules/docs/rules/frontend.md, then run `make rules`; local edits here are not kept. -->
# Frontend Requirements

Ignore this document if this is not a frontend application.

#### Responsive Design
All pages consider different widths (phones, tablets, and larger displays) and fit their content without horizontal scrolling unless that is intended. Check at a desktop width and a mobile width. Dark mode exists for every shared component.

### CSS

#### Styles
- SCSS is the preferred way to style. Avoid utility-class frameworks such as Tailwind.
- Stylesheets are loaded from files so the browser can cache them. Don't use inline `style` attributes or `<style>` tags unless they are unavoidable (for example, a value that is only known at runtime, or CSS modules).
- Styles are either app-wide or view-specific. App-wide styles are resets, fonts, themes, colors, typography, spacing, UI components and libraries. View-specific styles stay lean and only make the changes unique to that view.
- Styling is layered. Apply the lowest layer that works:
  1. **Library:** global/native styles and external libraries.
  2. **App:** theme tokens, fonts, and shared UI components, used across the app.
  3. **View:** overrides specific to one page. These should be minimal; a view needing many overrides probably wants a new or changed shared component.

  #### Class Names and IDs
Class names are similar to OOCSS: a single dash for inheritance, namespacing, or a relationship with a component (`ui-button-icon`); two dashes for states of a single class (`ui-button--active`); underscores for one term made of several words (`active_users`, `user_logins`). `id` attributes aren't used unless a library requires them.

#### Native Components
Avoid native dialogs (`alert`, `confirm`, `prompt`); use the modal UI component or a shared dialog helper. Native form controls (text inputs, selects, checkboxes, radios) are used through their matching UI components so they look and behave the same on every device.

### JavaScript

#### Loading Scripts
Scripts are loaded from bundled files so the browser can cache them, never written inline in HTML, except data that can't be cached or a snippet that must be inline. Use a typed language for web code.

#### API errors
Any failed API call shows an error to the user: the API client throws an error with a readable message, and the calling view shows it. Don't swallow failures silently. A failed authentication requires signing in again, which the client handles centrally by clearing the credentials and signing the user out.

#### API clients
API calls are organized by the API they integrate with. There is a base client, and each resource has its own module (one per resource, matching the data files). Views call these modules, never `fetch` directly. If a second API is integrated, each API gets its own folder.

### Structure

#### UI Components
Common recurring pieces (buttons, inputs, text fields, selects, dropdowns, checkboxes, radios, form elements, modals, panes, cards, and so on) live in their own files in a shared UI components folder. Before adding markup for one of these, use or extend the existing component.
- Each component has its own stylesheet, and its own script when it needs one to work (a modal, not a button).
- A component's root element (its outermost, parent-most element) has a class prefixed `ui-` (`ui-button`, `ui-modal`). Only the root needs the prefix; its children can use any class names.
- Every UI component supports light and dark mode.
- Anything the user can interact with has at least a subtle hover state; things they can't interact with shouldn't have one.
- Typography and spacing come from the theme scale, not one-off values. Typography is defined in one stylesheet, and margins and padding in one stylesheet.

#### Views
Every page is its own view, in a views directory. A view's folder holds every file for it (markup, scripts, styles) and its page-specific components; shared components stay in a shared folder. A view's root element (its outermost, parent-most element) has a lowercase class prefixed `view-` (`view-studies-list`). Only the root needs the prefix; its children can use any class names. The view's stylesheet may override UI component styles. Areas for different roles or "realms" each get their own folder inside the views directory, unless there is only one. A view sets its own page title where it makes sense.

#### Library Utilities
Pure helper functions that aren't tied to one data entity live in a shared "util" folder.

#### Accessibility Standards
Follow [WCAG 2.1](https://www.w3.org/TR/WCAG21/). Use ARIA attributes where native semantics aren't enough, and keep controls reachable and operable by keyboard.

#### Compilers
Development builds are not minified or obfuscated and provide source maps. Production builds are minified and optimized for performance. Don't override the toolchain's defaults without a reason.
