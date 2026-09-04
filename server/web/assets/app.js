(() => {
  "use strict";

  const state = { token: null, refreshToken: null, me: null, budgets: [], selected: null, accounts: [], categories: [], summary: null, requests: [], allowances: [] };
  const $ = (id) => document.getElementById(id);
  const authView = $("auth-view");
  const appView = $("app-view");
  const dialog = $("form-dialog");
  let authMode = "login";

  async function api(path, options = {}, mayRefresh = true) {
    const headers = { Accept: "application/json", ...(options.headers || {}) };
    if (state.token) headers.Authorization = `Bearer ${state.token}`;
    if (options.body) headers["Content-Type"] = "application/json";
    const response = await fetch(`/api/v1${path}`, { ...options, headers });
    if (response.status === 401 && mayRefresh && state.refreshToken && !path.startsWith("/auth/")) {
      const tokens = await api("/auth/refresh", {
        method: "POST",
        body: JSON.stringify({ refresh_token: state.refreshToken }),
      }, false);
      state.token = tokens.access_token;
      state.refreshToken = tokens.refresh_token;
      return api(path, options, false);
    }
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
      state.refreshToken = result.refresh_token;
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
      can("view_reports") ? api(`/budgets/${id}/months/${month}`) : Promise.resolve({ ready_to_assign_minor: 0, total_assigned_minor: 0, total_overspent_minor: 0, allocation_version: state.selected.allocation_version, categories: [] }),
      can("view_accounts") ? api(`/budgets/${id}/accounts`) : Promise.resolve([]),
      can("view_categories") ? api(`/budgets/${id}/categories`) : Promise.resolve([]),
      can("view_transactions") ? api(`/budgets/${id}/transactions`) : Promise.resolve([]),
    ]);
    Object.assign(state, { summary, accounts, categories, transactions });
    state.requests = can("request_money") || can("approve_request")
      ? await api(`/budgets/${id}/requests`)
      : [];
    state.allowances = await api(`/budgets/${id}/allowances`);
    renderBudget();
    if (state.selected.effective_permission === "owner") await renderFamily();
    else $("family-panel").classList.add("hidden");
  }

  function renderBudget() {
    $("ready-value").textContent = money(state.summary.ready_to_assign_minor);
    $("assigned-value").textContent = money(state.summary.total_assigned_minor);
    $("overspent-value").textContent = money(-state.summary.total_overspent_minor);
    $("overspent-value").classList.toggle("negative", state.summary.total_overspent_minor > 0);
    renderCategories(); renderAccounts(); renderTransactions(); renderRequests(); renderAllowances();
    $("add-transaction-button").classList.toggle("hidden", !can("create_transaction"));
    $("add-account-button").classList.toggle("hidden", !can("manage_budget_structure"));
    $("add-category-button").classList.toggle("hidden", !can("manage_budget_structure"));
    $("move-money-button").classList.toggle("hidden", !can("move_money"));
    $("requests-panel").classList.toggle("hidden", !can("request_money") && !can("approve_request"));
    $("new-request-button").classList.toggle("hidden", !can("request_money"));
    $("metrics-panel").classList.toggle("hidden", !can("view_reports"));
    $("plan-panel").classList.toggle("hidden", !can("view_reports"));
    $("accounts-panel").classList.toggle("hidden", !can("view_accounts"));
    $("transactions-panel").classList.toggle("hidden", !can("view_transactions"));
    $("export-json-button").classList.toggle("hidden", !can("export_data"));
    $("allowances-panel").classList.toggle("hidden", !state.allowances.length && !can("manage_allowances"));
    $("new-allowance-button").classList.toggle("hidden", !can("manage_allowances"));
  }

  function renderCategories() {
    const table = $("category-table"); table.replaceChildren();
    state.summary.categories.forEach((category) => {
      const row = document.createElement("tr");
      row.append(cell(category.name));
      const assigned = cell(money(category.assigned_minor));
      if (can("assign_money")) {
        assigned.replaceChildren();
        const input = document.createElement("input"); input.value = decimal(category.assigned_minor); input.setAttribute("aria-label", `Assigned to ${category.name}`);
        assigned.append(input);
        row.append(assigned, cell(money(category.activity_minor)));
        const available = cell(money(category.available_minor)); if (category.is_overspent) available.className = "negative"; row.append(available);
        const action = cell(""); const save = button("Save", "quiet compact");
        save.addEventListener("click", async () => {
          try { await api(`/budgets/${state.selected.id}/categories/${category.category_id}/assignment`, { method: "PUT", body: JSON.stringify({ month: currentMonth(), assigned_minor: parseMinor(input.value), expected_allocation_version: state.summary.allocation_version }) }); await selectBudget(state.selected.id); toast("Assignment updated"); }
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

  function renderRequests() {
    const list = $("request-list"); list.replaceChildren();
    state.requests.forEach((request) => {
      const category = state.categories.find((item) => item.id === request.destination_category_id);
      const row = document.createElement("div"); row.className = "transaction-row";
      row.append(labelBlock(request.reason || "Funding request", `${category?.name || "Category"} · ${request.status.replaceAll("_", " ")}`));
      const actions = document.createElement("div"); actions.className = "member-actions";
      const amount = document.createElement("strong"); amount.textContent = money(request.approved_amount_minor ?? request.requested_amount_minor); actions.append(amount);
      if (can("approve_request") && request.status === "pending") {
        const approve = button("Review", "quiet compact"); approve.addEventListener("click", () => openFields("Review request", [
          { id: "source", label: "Fund from", type: "select", options: state.summary.categories.filter((item) => item.category_id !== request.destination_category_id && item.available_minor > 0).map((item) => [item.category_id, `${item.name} · ${money(item.available_minor)}`]) },
          { id: "amount", label: "Approve amount", value: decimal(request.requested_amount_minor) },
          { id: "note", label: "Note", optional: true },
        ], async (values) => {
          const approved = parseMinor(values.amount); if (approved <= 0 || approved > request.requested_amount_minor) throw new Error("Enter an amount within the request.");
          await api(`/budgets/${state.selected.id}/requests/${request.id}/decision`, { method: "POST", body: JSON.stringify({ decision: "approve", expected_request_version: request.version, approved_amount_minor: approved, source_category_id: values.source, note: values.note }) });
          await selectBudget(state.selected.id); toast("Request approved with an allocation entry");
        }));
        const reject = button("Reject", "quiet compact"); reject.addEventListener("click", async () => {
          try { await api(`/budgets/${state.selected.id}/requests/${request.id}/decision`, { method: "POST", body: JSON.stringify({ decision: "reject", expected_request_version: request.version, note: "" }) }); await selectBudget(state.selected.id); toast("Request rejected"); }
          catch (error) { toast(error.message, true); }
        });
        actions.append(approve, reject);
      }
      row.append(actions); list.append(row);
    });
    if (!state.requests.length) list.append(emptyText("No requests."));
  }

  function renderAllowances() {
    const list = $("allowance-list"); list.replaceChildren();
    state.allowances.forEach((plan) => {
      const row = document.createElement("div"); row.className = "transaction-row";
      row.append(labelBlock(plan.name, `Next ${plan.next_issue_date} · ${plan.rollover_policy.replaceAll("_", " ")}`));
      const actions = document.createElement("div"); actions.className = "member-actions";
      const amount = document.createElement("strong"); amount.textContent = money(plan.amount_minor); actions.append(amount);
      if (can("manage_allowances") && plan.next_issue_date <= localToday()) {
        const issue = button("Issue", "quiet compact"); issue.addEventListener("click", async () => {
          try { await api(`/budgets/${state.selected.id}/allowances/${plan.id}/issue`, { method: "POST", body: JSON.stringify({ issue_date: plan.next_issue_date, expected_allocation_version: state.summary.allocation_version }) }); await selectBudget(state.selected.id); toast("Allowance issued with an allocation entry"); }
          catch (error) { toast(error.message, true); }
        }); actions.append(issue);
      }
      row.append(actions); list.append(row);
    });
    if (!state.allowances.length) list.append(emptyText("No allowance plans."));
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
        const delegate = button("Delegate", "quiet"); delegate.addEventListener("click", () => openFields(`Delegate to ${member.display_name}`, [
          { id: "account", label: "Spending account", type: "select", options: state.accounts.map((item) => [item.id, item.name]) },
          { id: "category", label: "Visible category", type: "select", options: state.categories.filter((item) => !item.is_archived && !item.system_type).map((item) => [item.id, item.name]) },
        ], async (values) => {
          await api(`/budgets/${state.selected.id}/grants`, { method: "PUT", body: JSON.stringify({ user_id: member.user_id, permission: "contribute" }) });
          await api(`/budgets/${state.selected.id}/access/${member.user_id}`, { method: "PUT", body: JSON.stringify({ capabilities: ["view_budget", "view_accounts", "view_categories", "view_transactions", "view_reports", "create_transaction", "request_money"], restrict_accounts: true, account_ids: [values.account], restrict_categories: true, category_ids: [values.category] }) });
          await api(`/budgets/${state.selected.id}/categories/${values.category}/delegation`, { method: "PUT", body: JSON.stringify({ delegated_user_id: member.user_id }) });
          await selectBudget(state.selected.id);
          toast(`Delegated one category to ${member.display_name}`);
        }));
        const remove = button("Remove", "quiet"); remove.addEventListener("click", async () => { if (!confirm(`Remove ${member.display_name} from the household?`)) return; try { await api(`/households/${household.id}/members/${member.user_id}`, { method: "DELETE" }); await renderFamily(); toast("Member removed"); } catch (error) { toast(error.message, true); } });
        actions.append(select, share, delegate, revoke, remove); row.append(actions);
      }
      list.append(row);
    });
  }

  $("sign-out").addEventListener("click", async () => {
    const refreshToken = state.refreshToken;
    state.token = null; state.refreshToken = null; state.selected = null;
    appView.classList.add("hidden"); authView.classList.remove("hidden"); $("password").value = "";
    if (refreshToken) {
      try { await api("/auth/logout", { method: "POST", body: JSON.stringify({ refresh_token: refreshToken }) }, false); }
      catch { /* Local sign-out still succeeds if the server is unavailable. */ }
    }
  });
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
  $("move-money-button").addEventListener("click", () => openFields("Move money", [
    { id: "source_category_id", label: "From category", type: "select", options: state.summary.categories.filter((item) => item.available_minor > 0).map((item) => [item.category_id, `${item.name} · ${money(item.available_minor)}`]) },
    { id: "destination_category_id", label: "To category", type: "select", options: state.summary.categories.map((item) => [item.category_id, item.name]) },
    { id: "amount", label: "Amount" },
    { id: "note", label: "Reason", optional: true },
  ], async (values) => {
    if (values.source_category_id === values.destination_category_id) throw new Error("Choose two different categories.");
    const amount = parseMinor(values.amount);
    if (amount <= 0) throw new Error("Enter an amount greater than zero.");
    await api(`/budgets/${state.selected.id}/allocation-transfers`, { method: "POST", body: JSON.stringify({
      source_category_id: values.source_category_id,
      destination_category_id: values.destination_category_id,
      amount_minor: amount,
      occurred_on: localToday(),
      note: values.note,
      expected_allocation_version: state.summary.allocation_version,
    }) });
    await selectBudget(state.selected.id); toast("Money moved with an audit entry");
  }));
  $("add-transaction-button").addEventListener("click", () => openFields("New transaction", [
    { id: "account", label: "Account", type: "select", options: state.accounts.filter((item) => !item.is_closed).map((item) => [item.id, item.name]) },
    { id: "payee", label: "Payee" }, { id: "amount", label: "Amount" },
    { id: "direction", label: "Direction", type: "select", options: [["expense", "Expense"], ["income", "Income"]] },
    { id: "category", label: "Category", type: "select", optional: true, options: [["", "Uncategorized / Ready to assign"], ...state.categories.filter((item) => !item.is_archived).map((item) => [item.id, item.name])] },
    { id: "date", label: "Date", type: "date", value: localToday() }, { id: "memo", label: "Memo", optional: true },
  ], async (values) => {
    let amount = Math.abs(parseMinor(values.amount)); if (values.direction === "expense") amount = -amount;
    await api(`/budgets/${state.selected.id}/transactions`, { method: "POST", body: JSON.stringify({ account_id: values.account, category_id: values.category || null, amount_minor: amount, occurred_on: values.date, payee_name: values.payee, memo: values.memo }) }); await selectBudget(state.selected.id); toast("Transaction saved");
  }));
  $("new-request-button").addEventListener("click", () => openFields("Request money", [
    { id: "category", label: "Category", type: "select", options: state.categories.filter((item) => !item.is_archived && !item.system_type).map((item) => [item.id, item.name]) },
    { id: "amount", label: "Amount" },
    { id: "reason", label: "What is this for?" },
  ], async (values) => {
    const amount = parseMinor(values.amount); if (amount <= 0) throw new Error("Enter an amount greater than zero.");
    await api(`/budgets/${state.selected.id}/requests`, { method: "POST", body: JSON.stringify({ destination_category_id: values.category, requested_amount_minor: amount, reason: values.reason }) });
    await selectBudget(state.selected.id); toast("Request sent");
  }));
  $("new-allowance-button").addEventListener("click", () => openFields("New allowance", [
    { id: "source", label: "Fund from", type: "select", options: state.categories.filter((item) => !item.delegated_user_id && !item.system_type).map((item) => [item.id, item.name]) },
    { id: "destination", label: "Delegated category", type: "select", options: state.categories.filter((item) => item.delegated_user_id && !item.system_type).map((item) => [item.id, item.name]) },
    { id: "name", label: "Plan name" }, { id: "amount", label: "Amount" },
    { id: "next_date", label: "First issue date", type: "date", value: localToday() },
    { id: "recurrence", label: "Recurrence", type: "select", options: [["week", "Weekly"], ["month", "Monthly"]] },
    { id: "rollover", label: "Unused money", type: "select", options: [["rollover", "Rolls over"], ["use_it_or_lose_it", "Use it or lose it"]] },
  ], async (values) => {
    const destination = state.categories.find((item) => item.id === values.destination);
    const amount = parseMinor(values.amount); if (!destination || amount <= 0) throw new Error("Choose a delegated category and positive amount.");
    await api(`/budgets/${state.selected.id}/allowances`, { method: "POST", body: JSON.stringify({ delegated_user_id: destination.delegated_user_id, source_category_id: values.source, name: values.name, amount_minor: amount, next_issue_date: values.next_date, recurrence_unit: values.recurrence, interval_count: 1, rollover_policy: values.rollover, splits: [{ destination_category_id: destination.id, amount_minor: amount }] }) });
    await selectBudget(state.selected.id); toast("Allowance plan created");
  }));
  $("export-button").addEventListener("click", async () => {
    try {
      const response = await fetch(`/api/v1/budgets/${state.selected.id}/export.csv`, {
        headers: { Authorization: `Bearer ${state.token}` },
      });
      if (!response.ok) throw new Error(`Export failed (${response.status})`);
      const url = URL.createObjectURL(await response.blob());
      const link = document.createElement("a");
      link.href = url;
      link.download = `${state.selected.name.replace(/[^a-z0-9]+/gi, "-").toLowerCase()}-export.csv`;
      link.click();
      window.setTimeout(() => URL.revokeObjectURL(url), 1000);
      toast("CSV export downloaded");
    } catch (error) { toast(error.message, true); }
  });
  $("export-json-button").addEventListener("click", async () => {
    try {
      const response = await fetch(`/api/v1/budgets/${state.selected.id}/export.json`, {
        headers: { Authorization: `Bearer ${state.token}` },
      });
      if (!response.ok) throw new Error(`Audit export failed (${response.status})`);
      const url = URL.createObjectURL(await response.blob());
      const link = document.createElement("a"); link.href = url;
      link.download = `${state.selected.name.replace(/[^a-z0-9]+/gi, "-").toLowerCase()}-audit.json`;
      link.click(); window.setTimeout(() => URL.revokeObjectURL(url), 1000);
      toast("Audit JSON downloaded");
    } catch (error) { toast(error.message, true); }
  });
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

  function can(capability) {
    if (state.selected?.effective_permission === "owner") return true;
    if (Array.isArray(state.selected?.capabilities)) return state.selected.capabilities.includes(capability);
    if (["create_transaction", "request_money"].includes(capability)) {
      return ["contribute", "manage"].includes(state.selected?.effective_permission);
    }
    if (["view_budget", "view_accounts", "view_account_balances", "view_categories", "view_transactions", "view_reports", "view_allocation_history"].includes(capability)) {
      return Boolean(state.selected?.effective_permission);
    }
    return state.selected?.effective_permission === "manage";
  }
  function currentMonth() { const now = new Date(); return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-01`; }
  function localToday() { const now = new Date(); return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`; }
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
