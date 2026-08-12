defmodule Api.StewardRouter do
  @moduledoc """
  The Steward surface (individual Bearer credentials, or HTTP Basic for the browser):
  `GET /v1/queue`, `POST /v1/decisions` (JSON), and the minimal HTML queue page at `/` with
  plain form posts to `/decide` — no JS build, same engine decisions underneath.
  """
  use Plug.Router
  require EEx

  plug(Api.Auth, :steward)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json, :urlencoded], json_decoder: JSON)
  plug(:dispatch)

  get "/v1/queue" do
    json(conn, 200, Api.Steward.queue())
  end

  post "/v1/decisions" do
    if conn.assigns.auth_scheme == :bearer do
      {status, body} = Api.Steward.decide(conn.body_params, conn.assigns.steward_principal)
      json(conn, status, body)
    else
      json(conn, 403, %{error: "JSON decisions require an individual Bearer credential"})
    end
  end

  # ── the minimal queue page ──────────────────────────────────────────────────
  get "/" do
    conn = fetch_query_params(conn)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(
      200,
      page(
        Api.Steward.queue(),
        conn.query_params["notice"],
        form_base(conn),
        Api.Auth.csrf_token(conn.assigns.steward_principal)
      )
    )
  end

  post "/decide" do
    if conn.assigns.auth_scheme == :basic and
         Api.Auth.valid_csrf?(conn.assigns.steward_principal, conn.body_params["_csrf_token"]) do
      {status, body} =
        conn.body_params
        |> form_to_decision()
        |> Api.Steward.decide(conn.assigns.steward_principal)

      notice =
        case status do
          200 -> "applied #{body[:applied]}"
          _ -> "rejected (#{status}): #{inspect(body)}"
        end

      conn
      |> put_resp_header(
        "location",
        "#{steward_path(conn)}?notice=#{URI.encode_www_form(notice)}"
      )
      |> send_resp(303, "")
    else
      json(conn, 403, %{error: "invalid or missing CSRF token"})
    end
  end

  match _ do
    json(conn, 404, %{error: "not found"})
  end

  # forms send flat string params; decisions speak the JSON shapes. The split selection
  # arrives as checkbox values (codes[] -> list); a string still splits for curl-style posts.
  defp form_to_decision(%{"kind" => "split"} = p),
    do: %{
      "kind" => "split",
      "key" => p["key"],
      "codes" => split_codes(p["codes"]),
      "case_id" => p["case_id"],
      "evidence_offset" => parse_offset(p["evidence_offset"]),
      "reason" => p["reason"]
    }

  defp form_to_decision(%{"keys" => keys} = p) when is_binary(keys),
    do:
      p
      |> Map.put("keys", String.split(keys, "+", trim: true))
      |> Map.update("evidence_offset", nil, &parse_offset/1)

  defp form_to_decision(p), do: Map.update(p, "evidence_offset", nil, &parse_offset/1)

  defp split_codes(codes) when is_list(codes), do: codes
  defp split_codes(codes) when is_binary(codes), do: String.split(codes, ~r/[\s,]+/, trim: true)
  defp split_codes(_), do: []

  defp parse_offset(offset) when is_integer(offset), do: offset

  defp parse_offset(offset) when is_binary(offset) do
    case Integer.parse(offset) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_offset(_), do: nil

  # mounted under /steward by the front router — Location must include the mount
  defp steward_path(%Plug.Conn{script_name: []}), do: "/"
  defp steward_path(%Plug.Conn{script_name: parts}), do: "/" <> Enum.join(parts, "/")

  # form actions must be ABSOLUTE: the page lives at /steward (no trailing slash), so a relative
  # action="<%= base %>/decide" resolves to /decide — outside the mount. "" when standalone -> "/decide".
  defp form_base(conn) do
    case steward_path(conn) do
      "/" -> ""
      base -> base
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end

  # HTML-escape every interpolated value before it lands in the page. The notice query param is
  # attacker-controllable and proposal by/reason are steward free text; source/ref/value/code/key
  # all originate in ingested third-party data. Coerce to string first so keys/atoms/ints escape
  # uniformly (the same String.Chars contract the default EEx output already required).
  defp h(value), do: value |> to_string() |> Plug.HTML.html_escape()

  # ── EEx template (compiled) ─────────────────────────────────────────────────
  EEx.function_from_string(
    :defp,
    :page,
    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1"/>
      <title>Steward queue — golden records</title>
      <style>
        :root { color-scheme: dark; }
        body { background:#0e1116; color:#e6edf3; font:14px/1.55 system-ui, sans-serif; max-width:880px; margin:32px auto; padding:0 16px; }
        h1 { font-size:20px; } h2 { font-size:15px; margin-top:28px; color:#e8b94a; }
        .item { border:1px solid #232a33; border-radius:10px; padding:14px 16px; margin:12px 0; background:#161b22; }
        .item.flag { border-color:#7a3b41; }
        code { background:#1b2230; border-radius:5px; padding:1px 6px; font-size:12.5px; }
        .muted { color:#8b949e; } .notice { color:#57c878; }
        .why { color:#b9c2cc; border-left:3px solid #7a3b41; padding:4px 10px; margin:10px 0; }
        .codecell { display:inline-block; margin:2px 10px 2px 0; }
        .srcs { font-size:11px; color:#8b949e; margin-left:4px; }
        .src { color:#57c878; margin-left:4px; }
        .bridge-src { color:#f0a857; margin-left:4px; }
        .owner { font-size:10px; color:#6ea8fe; border:1px solid #2c3a55; border-radius:999px; padding:0 6px; margin-left:2px; vertical-align:1px; }
        .owner.none { color:#f0a857; border-color:#4d3a23; }
        .bridge-row { margin:6px 0; padding:7px 10px; border:1px dashed #4d3a3d; border-radius:8px; }
        .members-row { margin:3px 0; }
        label.pick { display:block; margin:5px 0; cursor:pointer; }
        label.pick input { margin-right:8px; }
        form { margin:8px 8px 0 0; }
        form.inline { display:inline-block; }
        input[type=text] { background:#1b2230; color:#e6edf3; border:1px solid #232a33; border-radius:6px; padding:5px 8px; }
        button { background:#1b2230; color:#e6edf3; border:1px solid #3b4351; border-radius:999px; padding:6px 14px; cursor:pointer; }
        button.danger { border-color:#f0616d; color:#f0616d; }
        button.go { border-color:#6ea8fe; color:#6ea8fe; }
        details { margin-top:10px; }
        summary { cursor:pointer; color:#8b949e; }
      </style>
    </head>
    <body>
      <h1>Steward queue <span class="muted">(<%= queue.open %> open)</span></h1>
      <%= if notice do %><p class="notice"><%= h(notice) %></p><% end %>
      <%= if queue.open == 0 do %><p class="muted">Nothing needs a human right now — the engine resolved everything it was allowed to.</p><% end %>

      <%= if queue.merges != [] do %><h2>Merge proposals — gated, never automatic</h2><% end %>
      <%= for m <- queue.merges do %>
        <div class="item flag">
          <div><b><%= h(Enum.join(m.keys, " + ")) %></b> <span class="muted">— proposed merge</span></div>
          <%= if m.bridges == [] do %>
            <p class="why">These keys now <b>directly share</b> a code that each carries as its own —
            same dilemma: one product, or a reused code. The engine won't guess.</p>
          <% else %>
            <% b = hd(m.bridges) %>
            <% extra = length(m.bridges) - 1 %>
            <p class="why">Until <b><%= h(b.date) %></b>, <%= h(Enum.join(m.keys, " and ")) %> were
            <b>separate products</b>, each backed by its own sources (shown per code below). Then
            <b class="bridge-src"><%= h(b.source) %></b>'s listing <code><%= h(b.ref) %></code> claimed a code
            from <b>both</b><%= if extra > 0, do: " (and " <> Integer.to_string(extra) <> " more listings do the same)" %>.
            That can mean one product listed twice — or a mislabeled listing. The engine never merges
            established identities on its own; it stopped here and is asking you.</p>
          <% end %>
          <%= for {key, codes} <- m.members do %>
            <div class="members-row"><b><%= h(key) %></b>:
              <%= for c <- codes do %>
                <span class="codecell"><code><%= h(c.code) %></code><span class="srcs">by
                  <%= for s <- c.sources do %><span class="<%= if s in m.bridge_sources, do: "bridge-src", else: "src" %>"><%= h(s) %></span><% end %>
                </span></span>
              <% end %>
            </div>
          <% end %>
          <%= if m.shared != [] do %>
            <div class="members-row"><span class="muted">directly shared:</span> <%= for c <- m.shared do %><code><%= h(c) %></code><% end %></div>
          <% end %>
          <%= for b <- m.bridges do %>
            <div class="bridge-row">
              <span class="muted">the new evidence (<%= h(b.date) %>):</span> <b class="bridge-src"><%= h(b.source) %></b> <span class="muted">listing</span> <code><%= h(b.ref) %></code>
              <span class="muted">claiming</span>
              <%= for c <- b.codes do %>
                <code><%= h(c.code) %></code><span class="owner<%= if c.owner == nil, do: " none" %>"><%= h(c.owner || "new") %></span>
              <% end %>
            </div>
          <% end %>
          <%= if m.proposal do %>
            <div class="muted">endorsed by <b><%= h(m.proposal.by) %></b><%= if m.proposal.reason do %> — “<%= h(m.proposal.reason) %>”<% end %> · awaiting a second steward</div>
          <% end %>
          <form method="post" action="<%= base %>/decide" class="inline">
            <input type="hidden" name="_csrf_token" value="<%= h(csrf) %>"/>
            <input type="hidden" name="kind" value="approve_merge"/>
            <input type="hidden" name="case_id" value="<%= h(m.case_id) %>"/>
            <input type="hidden" name="evidence_offset" value="<%= h(m.evidence_offset) %>"/>
            <input type="hidden" name="keys" value="<%= h(Enum.join(m.keys, "+")) %>"/>
            <input type="text" name="reason" placeholder="reason (optional)"/>
            <button class="go"><%= if m.proposal, do: "approve merge (2nd steward)", else: "propose — same product" %></button>
          </form>
          <form method="post" action="<%= base %>/decide" class="inline">
            <input type="hidden" name="_csrf_token" value="<%= h(csrf) %>"/>
            <input type="hidden" name="kind" value="reject_merge"/>
            <input type="hidden" name="case_id" value="<%= h(m.case_id) %>"/>
            <input type="hidden" name="evidence_offset" value="<%= h(m.evidence_offset) %>"/>
            <input type="hidden" name="keys" value="<%= h(Enum.join(m.keys, "+")) %>"/>
            <input type="text" name="reason" placeholder="reason (optional)"/>
            <button class="danger">reject — two products</button>
          </form>
        </div>
      <% end %>

      <%= if queue.attributes != [] do %><h2>Attribute ties — the engine won't guess</h2><% end %>
      <%= for a <- queue.attributes do %>
        <div class="item">
          <div><b><%= h(a.field) %></b> on <b><%= h(a.key) %></b>:
            <%= for c <- a.candidates do %><code><%= h(c.source) %> says <%= h(c.value) %></code><% end %>
          </div>
          <form method="post" action="<%= base %>/decide">
            <input type="hidden" name="_csrf_token" value="<%= h(csrf) %>"/>
            <input type="hidden" name="kind" value="resolve_attribute"/>
            <input type="hidden" name="case_id" value="<%= h(a.case_id) %>"/>
            <input type="hidden" name="evidence_offset" value="<%= h(a.evidence_offset) %>"/>
            <input type="hidden" name="key" value="<%= h(a.key) %>"/>
            <input type="hidden" name="field" value="<%= h(a.field) %>"/>
            <input type="text" name="value" placeholder="the correct value" required/>
            <input type="text" name="reason" placeholder="reason (optional)"/>
            <button class="go">pick</button>
          </form>
        </div>
      <% end %>

      <%= if queue.repairs != [] do %>
        <h2>Recently merged — select what doesn't belong</h2>
        <p class="muted">A wrong merge is cheap to undo: tick the codes that are NOT this product and split them
        back out. Attributes and media follow their codes automatically; the carved-out product gets its own id.</p>
      <% end %>
      <%= for r <- queue.repairs do %>
        <div class="item">
          <div><b><%= h(r.key) %></b> <span class="muted">absorbed <%= h(Enum.join(r.merged_from, ", ")) %></span></div>
          <form method="post" action="<%= base %>/decide">
            <input type="hidden" name="_csrf_token" value="<%= h(csrf) %>"/>
            <input type="hidden" name="kind" value="split"/>
            <input type="hidden" name="case_id" value="<%= h(r.case_id) %>"/>
            <input type="hidden" name="evidence_offset" value="<%= h(r.evidence_offset) %>"/>
            <input type="hidden" name="key" value="<%= h(r.key) %>"/>
            <%= for c <- r.codes do %>
              <label class="pick"><input type="checkbox" name="codes[]" value="<%= h(c.code) %>"/><code><%= h(c.code) %></code>
                <span class="muted">claimed by <%= h(Enum.join(c.sources, ", ")) %></span></label>
            <% end %>
            <input type="text" name="reason" placeholder="reason (optional)"/>
            <button class="danger">split the selected out</button>
          </form>
        </div>
      <% end %>
    </body>
    </html>
    """,
    [:queue, :notice, :base, :csrf]
  )
end
