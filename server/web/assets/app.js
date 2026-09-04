(() => {
  "use strict";

  const state = { token: null, me: null, budgets: [], selected: null, accounts: [], categories: [], summary: null };
  const $ = (id) => document.getElementById(id);
  const authView = $("auth-view");
  const appView = $("app-view");
  const dialog = $("form-dialog");
  let authMode = "login";

  async function api(path, options = {}) {
    const headers = { Accept: "application/json", ...(options.headers || {}) };
    if (state.token) headers.Authorization = `Bearer ${state.token}`;
    if (options.body) headers["Content-Type"] = "application/json";
    const response = await fetch(`/api/v1${path}`, { ...options, headers });
    if (response.status === 204) return null;
    const data = await response.json().catch(() => ({}));
    if (!response.ok) {
      const detail = typeof data.detail === "string" ? data.detail : data.detail?.message;
      throw new Error(detail || `Request failed (${response.status})`);
    }
    return data;
  }

  document.querySelectorAll("[data-auth-mode]").forEach((button) => {
    button.addEventListener("click", () => {
      authMode = button.dataset.authMode;
      document.querySelectorAll("[data-auth-mode]").forEach((item) => item.classList.toggle("active", item === button));
      document.querySelectorAll(".setup-only").forEach((item) => item.classList.toggle("hidden", authMode !== "setup"));
      document.querySelectorAll(".invite-only").forEach((item) => item.classList.toggle("hidden", authMode !== "invite"));
      $("display-name-field").classList.toggle("hidden", authMode === "login");
      $("household-name").parentElement.classList.toggle("hidden", authMode !== "setup");
      $("email-field").classList.toggle("hidden", authMode === "invite");
      $("auth-submit").textContent = authMode === "login" ? "Sign in" : authMode === "setup" ? "Create owner account" : "Join household";
      $("password").autocomplete = authMode === "login" ? "current-password" : "new-password";
      $("auth-error").textContent = "";
    });
  });

  $("auth-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    $("auth-error").textContent = "";
    try {
      let result;
      if (authMode === "login") {
        result = await api("/auth/login", { method: "POST", body: JSON.stringify({ email: $("email").value, password: $("password").value }) });
      } else if (authMode === "setup") {
        result = await api("/auth/bootstrap", { method: "POST", body: JSON.stringify({
          email: $("email").value,
          password: $("password").value,
          display_name: $("display-name").value,
          household_name: $("household-name").value,
        }) });
      } else {
        result = await api("/auth/accept-invitation", { method: "POST", body: JSON.stringify({
          invitation_token: $("invite-token").value,
          password: $("password").value,
          display_name: $("display-name").value,
        }) });
      }
      state.token = result.access_token;
      await loadSession();
      authView.classList.add("hidden");
      appView.classList.remove("hidden");
    } catch (error) {
      $("auth-error").textContent = error.message;
    }
  });

  async function loadSession() {
    [state.me, state.budgets] = await Promise.all([api("/me"), api("/budgets")]);
    $("user-name").textContent = state.me.display_name;
    renderBudgets();
    const ownerHousehold = state.me.households.find((item) => item.role === "owner" && item.is_active);
    $("new-budget-button").classList.toggle("hidden", !ownerHousehold);
    if (state.budgets.length) await selectBudget(state.budgets[0].id);
  }

  function renderBudgets() {
    const list = $("budget-list");
    list.replaceChildren();
    state.budgets.forEach((budget) => {
      const button = document.createElement("button");
      button.textContent = budget.name;
      button.classList.toggle("active", state.selected?.id === budget.id);
      button.addEventListener("click", () => selectBudget(budget.id));
      list.append(button);
    });
  }

  async function selectBudget(id) {
    state.selected = state.budgets.find((item) => item.id === id);
    renderBudgets();
    $("empty-state").classList.add("hidden");
    $("budget-content").classList.remove("hidden");
    $("budget-title").textContent = state.selected.name;
    $("permission-badge").textContent = state.selected.effective_permission;
    $("month-label").textContent = new Intl.DateTimeFormat(undefined, { month: "long", year: "numeric" }).format(new Date());
    const month = currentMonth();
    const [summary, accounts, categories, transactions] = await Promise.all([
      api(`/budgets/${id}/months/${month}`), api(`/budgets/${id}/accounts`),
      api(`/budgets/${id}/categories`), api(`/budgets/${id}/transactions`),
    ]);
    Object.assign(state, { summary, accounts, categories, transactions });
    renderBudget();
    if (state.selected.effective_permission === "owner") await renderFamily();
    else $("family-panel").classList.add("hidden");
  }

  function renderBudget() {
    $("ready-value").textContent = money(state.summary.ready_to_assign_minor);
    $("assigned-value").textContent = money(state.summary.total_assigned_minor);
    $("overspent-value").textContent = money(-state.summary.total_overspent_minor);
    $("overspent-value").classList.toggle("negative", state.summary.total_overspent_minor > 0);
    renderCategories(); renderAccounts(); renderTransactions();
    $("add-transaction-button").classList.toggle("hidden", !canContribute());
    $("add-account-button").classList.toggle("hidden", !canManage());
    $("add-category-button").classList.toggle("hidden", !canManage());
  }

  function renderCategories() {
    const table = $("category-table"); table.replaceChildren();
    state.summary.categories.forEach((category) => {
      const row = document.createElement("tr");
      row.append(cell(category.name));
      const assigned = cell(money(category.assigned_minor));
      if (canManage()) {
        assigned.replaceChildren();
        const input = document.createElement("input"); input.value = decimal(category.assigned_minor); input.setAttribute("aria-label", `Assigned to ${category.name}`);
        assigned.append(input);
        row.append(assigned, cell(money(category.activity_minor)));
        const available = cell(money(category.available_minor)); if (category.is_overspent) available.className = "negative"; row.append(available);
        const action = cell(""); const save = button("Save", "quiet compact");
        save.addEventListener("click", async () => {
          try { await api(`/budgets/${state.selected.id}/categories/${category.category_id}/assignment`, { method: "PUT", body: JSON.stringify({ month: currentMonth(), assigned_minor: parseMinor(input.value) }) }); await selectBudget(state.selected.id); toast("Assignment updated"); }
          catch (error) { toast(error.message, true); }
        }); action.append(save); row.append(action);
      } else {
        row.append(assigned, cell(money(category.activity_minor)));
        const available = cell(money(category.available_minor)); if (category.is_overspent) available.className = "negative"; row.append(available, cell(""));
      }
      table.append(row);
    });
  }

  function renderAccounts() {
    const list = $("account-list"); list.replaceChildren();
    state.accounts.forEach((account) => {
      const row = document.createElement("div"); row.className = "account-row";
      row.append(labelBlock(account.name, `${account.account_type}${account.is_closed ? " · Closed" : ""}`));
      if (account.reconciled_balance_minor !== null) row.append(document.createTextNode(money(account.reconciled_balance_minor)));
      list.append(row);
    });
    if (!state.accounts.length) list.append(emptyText("No accounts yet."));
  }

  function renderTransactions() {
    const list = $("transaction-list"); list.replaceChildren();
    state.transactions.slice(0, 25).forEach((transaction) => {
      const row = document.createElement("div"); row.className = "transaction-row";
      row.append(labelBlock(transaction.payee_name || "No payee", `${transaction.occurred_on}${transaction.is_cleared ? " · Cleared" : ""}`));
      const amount = document.createElement("strong"); amount.textContent = money(transaction.amount_minor); if (transaction.amount_minor < 0) amount.className = "negative"; row.append(amount); list.append(row);
    });
    if (!state.transactions.length) list.append(emptyText("No transactions yet."));
  }

  async function renderFamily() {
    const household = state.me.households.find((item) => item.id === state.selected.household_id && item.role === "owner");
    const panel = $("family-panel"); panel.classList.toggle("hidden", !household); if (!household) return;
    const members = await api(`/households/${household.id}/members`); const list = $("member-list"); list.replaceChildren();
    members.forEach((member) => {
      const row = document.createElement("div"); row.className = "member-row";
      row.append(labelBlock(member.display_name, `${member.role} · ${member.is_active ? member.email : "Inactive"}`));
      if (member.role !== "owner" && member.is_active) {
        const actions = document.createElement("div"); actions.className = "member-actions";
        const select = document.createElement("select"); ["view", "contribute", "manage"].forEach((value) => { const option = document.createElement("option"); option.value = value; option.textContent = value; select.append(option); });
        const share = button("Share", "quiet"); share.addEventListener("click", async () => { try { await api(`/budgets/${state.selected.id}/grants`, { method: "PUT", body: JSON.stringify({ user_id: member.user_id, permission: select.value }) }); toast(`Shared with ${member.display_name}`); } catch (error) { toast(error.message, true); } });
        const revoke = button("Revoke", "quiet"); revoke.addEventListener("click", async () => { try { await api(`/budgets/${state.selected.id}/grants/${member.user_id}`, { method: "DELETE" }); toast("Budget access revoked"); } catch (error) { toast(error.message, true); } });
        const remove = button("Remove", "quiet"); remove.addEventListener("click", async () => { if (!confirm(`Remove ${member.display_name} from the household?`)) return; try { await api(`/households/${household.id}/members/${member.user_id}`, { method: "DELETE" }); await renderFamily(); toast("Member removed"); } catch (error) { toast(error.message, true); } });
        actions.append(select, share, revoke, remove); row.append(actions);
      }
      list.append(row);
    });
  }

  $("sign-out").addEventListener("click", () => { state.token = null; state.selected = null; appView.classList.add("hidden"); authView.classList.remove("hidden"); $("password").value = ""; });
  $("new-budget-button").addEventListener("click", () => openFields("New budget", [{ id: "name", label: "Budget name" }, { id: "currency", label: "Currency code", value: "USD" }], async (values) => {
    const household = state.me.households.find((item) => item.role === "owner" && item.is_active);
    await api("/budgets", { method: "POST", body: JSON.stringify({ household_id: household.id, name: values.name, currency_code: values.currency }) }); await loadSession(); toast("Budget created");
  }));
  $("add-account-button").addEventListener("click", () => openFields("New account", [{ id: "name", label: "Account name" }, { id: "type", label: "Type", type: "select", options: ["checking", "savings", "cash", "credit", "loan", "tracking"] }], async (values) => {
    await api(`/budgets/${state.selected.id}/accounts`, { method: "POST", body: JSON.stringify({ name: values.name, account_type: values.type, is_on_budget: values.type !== "tracking" }) }); await selectBudget(state.selected.id); toast("Account added");
  }));
  $("add-category-button").addEventListener("click", () => openFields("New category", [{ id: "group", label: "Group name" }, { id: "name", label: "Category name" }], async (values) => {
    const group = await api(`/budgets/${state.selected.id}/category-groups`, { method: "POST", body: JSON.stringify({ name: values.group }) });
    await api(`/budgets/${state.selected.id}/categories`, { method: "POST", body: JSON.stringify({ group_id: group.id, name: values.name }) }); await selectBudget(state.selected.id); toast("Category added");
  }));
  $("add-transaction-button").addEventListener("click", () => openFields("New transaction", [
    { id: "account", label: "Account", type: "select", options: state.accounts.filter((item) => !item.is_closed).map((item) => [item.id, item.name]) },
    { id: "payee", label: "Payee" }, { id: "amount", label: "Amount" },
    { id: "direction", label: "Direction", type: "select", options: [["expense", "Expense"], ["income", "Income"]] },
    { id: "category", label: "Category", type: "select", optional: true, options: [["", "Uncategorized / Ready to assign"], ...state.categories.filter((item) => !item.is_archived).map((item) => [item.id, item.name])] },
    { id: "date", label: "Date", type: "date", value: new Date().toISOString().slice(0, 10) }, { id: "memo", label: "Memo", optional: true },
  ], async (values) => {
    let amount = Math.abs(parseMinor(values.amount)); if (values.direction === "expense") amount = -amount;
    await api(`/budgets/${state.selected.id}/transactions`, { method: "POST", body: JSON.stringify({ account_id: values.account, category_id: values.category || null, amount_minor: amount, occurred_on: values.date, payee_name: values.payee, memo: values.memo }) }); await selectBudget(state.selected.id); toast("Transaction saved");
  }));
  $("invite-button").addEventListener("click", () => openFields("Invite family member", [{ id: "email", label: "Email", type: "email" }, { id: "role", label: "Role", type: "select", options: [["adult", "Adult"], ["child", "Child"]] }], async (values) => {
    const household = state.me.households.find((item) => item.id === state.selected.household_id);
    const invitation = await api(`/households/${household.id}/invitations`, { method: "POST", body: JSON.stringify(values) });
    try { await navigator.clipboard.writeText(invitation.invitation_token); toast("Invitation code copied. It expires in 7 days."); }
    catch { toast(`Invitation code: ${invitation.invitation_token}`); }
  }));

  function openFields(title, fields, save) {
    $("dialog-title").textContent = title; $("dialog-error").textContent = ""; const container = $("dialog-fields"); container.replaceChildren();
    fields.forEach((field) => {
      const label = document.createElement("label"); label.textContent = field.label; let input;
      if (field.type === "select") { input = document.createElement("select"); (field.options || []).forEach((raw) => { const [value, text] = Array.isArray(raw) ? raw : [raw, raw]; const option = document.createElement("option"); option.value = value; option.textContent = text; input.append(option); }); }
      else { input = document.createElement("input"); input.type = field.type || "text"; input.value = field.value || ""; }
      input.id = `field-${field.id}`; input.required = !field.optional; label.append(input); container.append(label);
    });
    $("dialog-form").onsubmit = async (event) => { event.preventDefault(); const values = {}; fields.forEach((field) => { values[field.id] = $(`field-${field.id}`).value; }); try { await save(values); dialog.close(); } catch (error) { $("dialog-error").textContent = error.message; } };
    dialog.showModal();
  }

  function canContribute() { return ["contribute", "manage", "owner"].includes(state.selected?.effective_permission); }
  function canManage() { return ["manage", "owner"].includes(state.selected?.effective_permission); }
  function currentMonth() { const now = new Date(); return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-01`; }
  function currencyDigits() { return new Intl.NumberFormat(undefined, { style: "currency", currency: state.selected.currency_code }).resolvedOptions().maximumFractionDigits; }
  function money(value) { return new Intl.NumberFormat(undefined, { style: "currency", currency: state.selected.currency_code }).format(value / (10 ** currencyDigits())); }
  function decimal(value) { return (value / (10 ** currencyDigits())).toFixed(currencyDigits()); }
  function parseMinor(value) { const normalized = String(value).trim(); if (!/^-?\d+(\.\d+)?$/.test(normalized)) throw new Error("Enter a valid amount using a decimal point."); const [whole, fraction = ""] = normalized.split("."); const digits = currencyDigits(); if (fraction.length > digits) throw new Error(`This currency supports ${digits} decimal places.`); const sign = whole.startsWith("-") ? -1 : 1; const absoluteWhole = whole.replace("-", ""); const result = sign * (Number(absoluteWhole) * (10 ** digits) + Number(fraction.padEnd(digits, "0"))); if (!Number.isSafeInteger(result)) throw new Error("Amount is too large."); return result; }
  function cell(text) { const item = document.createElement("td"); item.textContent = text; return item; }
  function button(text, className) { const item = document.createElement("button"); item.type = "button"; item.className = className; item.textContent = text; return item; }
  function labelBlock(title, meta) { const item = document.createElement("div"); const strong = document.createElement("span"); strong.className = "row-title"; strong.textContent = title; const small = document.createElement("span"); small.className = "row-meta"; small.textContent = meta; item.append(strong, small); return item; }
  function emptyText(text) { const item = document.createElement("p"); item.className = "muted"; item.textContent = text; return item; }
  function toast(message, isError = false) { const item = $("toast"); item.textContent = message; item.classList.toggle("negative", isError); item.classList.remove("hidden"); window.setTimeout(() => item.classList.add("hidden"), 5000); }
})();
