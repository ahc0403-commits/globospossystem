/* Host-runtime driver. Load this reviewed CommonJS function in tools code mode.
 * It uses the already-connected tools object; no shell token or new login.
 */
module.exports = async function driveCloudRelease({ tools, root, directory, maxRequests = 1000 }) {
  const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
  const python = ["python3", "-B", root + "/scripts/cloud_deployment/bridge.py"];
  const command = args => [...python, ...args, "--directory", directory].map(quote).join(" ");
  const invoke = async args => {
    const result = await tools.exec_command({cmd: command(args), workdir: root, max_output_tokens: 18000});
    if (result.exit_code !== 0) throw new Error("Cloud bridge failed; stop and inspect the execution state");
    return JSON.parse(result.output);
  };
  const methods = {
    project: "mcp__codex_apps__supabase_get_project",
    query: "mcp__codex_apps__supabase_execute_sql",
    migrations: "mcp__codex_apps__supabase_list_migrations",
    apply: "mcp__codex_apps__supabase_apply_migration",
    functions: "mcp__codex_apps__supabase_list_edge_functions",
    function: "mcp__codex_apps__supabase_get_edge_function",
    "deploy-function": "mcp__codex_apps__supabase_deploy_edge_function",
  };
  const completed = [];
  for (let index = 0; index < maxRequests; index++) {
    const next = await invoke(["next", "--metadata-only"]);
    if (next.closed || next.waiting) return {closed: !!next.closed, waiting: !!next.waiting, completed};
    let request = next.request;
    if (next.requestDescriptor) {
      const descriptor = next.requestDescriptor;
      if (!/^[a-f0-9]{32}$/.test(descriptor.requestId) ||
          !Number.isInteger(descriptor.length) || descriptor.length <= 0 || descriptor.length > 8 * 1024 * 1024) {
        throw new Error("Invalid cloud request descriptor");
      }
      let serialized = "";
      while (serialized.length < descriptor.length) {
        const part = await invoke(["read-request", "--request-id", descriptor.requestId,
          "--offset", String(serialized.length), "--length", "12000"]);
        if (part.length !== descriptor.length || part.requestHash !== descriptor.requestHash ||
            typeof part.chunk !== "string" || !part.chunk.length) throw new Error("Cloud request changed during transfer");
        serialized += part.chunk;
      }
      request = JSON.parse(serialized);
      if (serialized.length !== descriptor.length || request.requestId !== descriptor.requestId ||
          request.requestHash !== descriptor.requestHash) throw new Error("Cloud request transfer mismatch");
    }
    if (request.project !== "ynriuoomotxuwhuxxmhj" || !methods[request.operation]) {
      throw new Error("Unrecognized cloud operation or project");
    }
    const args = request.operation === "project"
      ? {id: request.project}
      : {...request.arguments, project_id: request.project};
    // A mutation is invoked once. A thrown/uncertain result leaves the claim in
    // place; the operator must inspect remote state rather than repeat it.
    const result = await tools[methods[request.operation]](args);
    const response = await tools.exec_command({
      cmd: command(["reply", "--request-id", request.requestId]) +
        " <<'POS_CLOUD_TOOL_RESULT_8ac7a5'\n" + JSON.stringify(result) + "\nPOS_CLOUD_TOOL_RESULT_8ac7a5",
      workdir: root, max_output_tokens: 1000,
    });
    if (response.exit_code !== 0) throw new Error("Cloud reply failed; do not resubmit the operation");
    const accepted = JSON.parse(response.output);
    completed.push({operation: request.operation, requestId: request.requestId, ok: accepted.ok});
    if (!accepted.ok) return {blocked: true, completed};
  }
  throw new Error("Cloud operation count exceeded; stop this execution");
};
