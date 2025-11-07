# README rápido
#
# Objetivo: Dada uma página do Notion, baixar localmente **todas as páginas e subpáginas**
# como **Markdown**, incluindo **imagens/arquivos**, evitando duplicidades.
#
# Requisitos:
# - Ruby 3.1+ (recomendado)
# - Bundler
# - Token da Notion API (Internal Integration Token)
#
# Passos:
# 1) Salve os dois arquivos abaixo (Gemfile e notion_dump.rb) em uma pasta.
# 2) Exporte a variável de ambiente NOTION_TOKEN com seu token da Notion API.
#    Ex.: `export NOTION_TOKEN="secret_xxx"`
# 3) Instale dependências: `bundle install`
# 4) Rode: `ruby notion_dump.rb "URL_ou_ID_da_pagina" ./saida`
#    - Ex.: `ruby notion_dump.rb https://www.notion.so/minha-pagina-123abc456def7890abcd1234ef567890 ./dump`
# 5) A saída terá uma pasta por página com `index.md` e uma subpasta `assets/` para imagens/arquivos.
#
# Observações:
# - Evita duplicidade de páginas por `page_id` (Set in-memory) e de arquivos por hash (SHA256 do conteúdo).
# - Converte blocos comuns para Markdown (headings, parágrafos, listas, to-do, code, quote, callout, toggle, divider,
#   images, files, tabelas simples, etc.).
# - Percorre `child_page` e `child_database` (no caso de database, exporta cada página do DB).
# - URLs de arquivos/imagens do tipo `file` são temporárias; o script baixa imediatamente e versiona pelo hash.
#
# ────────────────────────────────────────────────────────────────────────────────
# Gemfile
# ────────────────────────────────────────────────────────────────────────────────
# Salve como: Gemfile


# ────────────────────────────────────────────────────────────────────────────────
# Helpers utilitários
# ────────────────────────────────────────────────────────────────────────────────
module Utils
  module_function

  def slugify(text)
    return "untitled" if text.nil? || text.strip.empty?
    text.to_s.parameterize(preserve_case: false, separator: "-")
  end

  # Extrai/normaliza ID de página de URLs do Notion
  def extract_notion_id(input)
    str = input.to_s.strip
    # IDs no Notion são UUIDs (32 hex com hifens). URLs geralmente terminam com ...<id>
    if str =~ /([0-9a-f]{32})/i
      raw = Regexp.last_match(1).downcase
      # Insere hifens no padrão 8-4-4-4-12
      return [raw[0,8], raw[8,4], raw[12,4], raw[16,4], raw[20,12]].join("-")
    end
    # Já pode estar com hifens
    if str =~ /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i
      return str[/[0-9a-f\-]{36}/i]
    end
    raise "Não foi possível extrair um page_id válido do input: #{input}"
  end

  def ensure_dir(path)
    FileUtils.mkdir_p(path) unless Dir.exist?(path)
  end

  def sha256(bytes)
    Digest::SHA256.hexdigest(bytes)
  end

  def fetch_binary(url, token: nil, limit: 5)
    raise "HTTP redirect too deep" if limit <= 0
    uri = URI(url)
    http = Net::HTTP
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{token}" if token

    response = http.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |h|
      h.request(request)
    end

    case response
    when Net::HTTPSuccess
      response.body
    when Net::HTTPRedirection
      fetch_binary(response["location"], token: token, limit: limit - 1)
    else
      raise "Falha ao baixar #{url}: #{response.code} #{response.message}"
    end
  end

  def safe_write(path, content)
    ensure_dir(File.dirname(path))
    File.open(path, "wb") { |f| f.write(content) }
  end

  def md_escape(text)
    # Escapes simples; Notion rich_text já vem com annotations; aqui protegemos #* etc quando preciso
    text.to_s
  end
end

# ────────────────────────────────────────────────────────────────────────────────
# Renderização Markdown de rich_text e blocos
# ────────────────────────────────────────────────────────────────────────────────
module Markdown
  module_function

  def render_rich_text_array(arr)
    return "" if arr.nil? || arr.empty?
    arr.map { |rt| render_rich_text(rt) }.join
  end

  def render_rich_text(rt)
    text = rt.dig("plain_text") || ""
    ann  = rt["annotations"] || {}
    href = rt["href"]

    t = Utils.md_escape(text)
    t = "**#{t}**" if ann["bold"]
    t = "*#{t}*"     if ann["italic"]
    t = "~~#{t}~~"   if ann["strikethrough"]
    t = "`#{t}`"     if ann["code"]
    # underline não tem markdown puro; ignorado ou usar <u>
    t = "<u>#{t}</u>" if ann["underline"]

    href ? "[#{t}](#{href})" : t
  end

  def render_block(block, ctx)
    type = block["type"]
    data = block[type]

    case type
    when "paragraph"
      content = render_rich_text_array(data["rich_text"]) 
      "#{content}\n\n"
    when "heading_1"
      "# #{render_rich_text_array(data["rich_text"])}\n\n"
    when "heading_2"
      "## #{render_rich_text_array(data["rich_text"])}\n\n"
    when "heading_3"
      "### #{render_rich_text_array(data["rich_text"])}\n\n"
    when "bulleted_list_item"
      "- #{render_rich_text_array(data["rich_text"])}\n"
    when "numbered_list_item"
      "1. #{render_rich_text_array(data["rich_text"])}\n"
    when "to_do"
      checked = data["checked"] ? "x" : " "
      "- [#{checked}] #{render_rich_text_array(data["rich_text"])}\n"
    when "toggle"
      summary = render_rich_text_array(data["rich_text"]) 
      "<details>\n<summary>#{summary}</summary>\n\n#{ctx.render_children(block)}\n</details>\n\n"
    when "quote"
      content = render_rich_text_array(data["rich_text"]) 
      "> #{content}\n\n"
    when "callout"
      content = render_rich_text_array(data["rich_text"]) 
      "> **ℹ️  #{content}**\n\n"
    when "divider"
      "\n---\n\n"
    when "code"
      lang = data["language"] || ""
      code = data["rich_text"].map { |r| r["plain_text"] }.join
      "```#{lang}\n#{code}\n```\n\n"
    when "image"
      url = data["type"] == "external" ? data.dig("external", "url") : data.dig("file", "url")
      alt = block.dig("image", "caption")&.map { |r| r["plain_text"] }&.join || ""
      local = ctx.download_asset(url)
      "![#{alt}](#{local})\n\n"
    when "file"
      url = data["type"] == "external" ? data.dig("external", "url") : data.dig("file", "url")
      name = data["caption"]&.map { |r| r["plain_text"] }&.join
      name ||= File.basename(URI(url).path)
      local = ctx.download_asset(url)
      "[#{name}](#{local})\n\n"
    when "bookmark"
      href = data["url"]
      "[#{href}](#{href})\n\n"
    when "embed"
      href = data["url"]
      "[Embed] #{href}\n\n"
    when "equation"
      exp = data.dig("expression")
      "$$\n#{exp}\n$$\n\n"
    when "table"
      # Renderização simples: obter linhas filhas (table_row)
      ctx.render_children_as_table(block)
    when "child_page"
      # Link simples para a child page (conteúdo completo será exportado na recursão)
      title = data["title"]
      child_id = block["id"]
      slug = Utils.slugify(title)
      "- [[#{title}]](./#{slug}_#{child_id[0,8]}/index.md)\n\n"
    when "child_database"
      title = data["title"] || "Database"
      "### #{title} (database)\n\n"
    else
      "<!-- Bloco não suportado: #{type} -->\n\n"
    end
  end
end

# ────────────────────────────────────────────────────────────────────────────────
# Classe de contexto da exportação (estado, cache, downloads, etc.)
# ────────────────────────────────────────────────────────────────────────────────
class ExportContext
  attr_reader :client, :root_out, :visited_pages, :asset_dir_by_page

  def initialize(client:, root_out:)
    @client = client
    @root_out = root_out
    @visited_pages = {}
    @asset_dir_by_page = {}
    Utils.ensure_dir(@root_out)
  end

  def page_dir(page_id, title)
    slug = Utils.slugify(title)
    File.join(@root_out, "#{slug}_#{page_id[0,8]}")
  end

  def ensure_assets_dir(page_dir)
    dir = File.join(page_dir, "assets")
    Utils.ensure_dir(dir)
    dir
  end

  # Faz download do asset e salva com nome = SHA256 + extensão inferida
  def download_asset(url)
    ext = File.extname(URI(url).path)
    ext = ".bin" if ext.nil? || ext.empty?

    # baixar (tente sem token; se 403, tenta com token)
    bytes = begin
      Utils.fetch_binary(url)
    rescue => e
      # fallback com token da Notion (alguns links expiram/precisam header)
      Utils.fetch_binary(url, token: ENV["NOTION_TOKEN"]) 
    end

    hash = Utils.sha256(bytes)
    fname = "#{hash}#{ext}"

    # salva no diretório atual de assets (depende de quem chamou)
    current_assets = @current_assets_dir || @last_assets_dir || File.join(@root_out, "assets")
    Utils.ensure_dir(current_assets)
    dest = File.join(current_assets, fname)
    Utils.safe_write(dest, bytes) unless File.exist?(dest)
    rel = relative_path_from(dest, @current_page_dir)
    rel
  end

  def with_page_dirs(page_dir)
    prev_assets = @current_assets_dir
    prev_page   = @current_page_dir
    @current_assets_dir = ensure_assets_dir(page_dir)
    @current_page_dir   = page_dir
    @last_assets_dir    = @current_assets_dir
    yield
  ensure
    @current_assets_dir = prev_assets
    @current_page_dir   = prev_page
  end

  def relative_path_from(path, base)
    Pathname.new(path).relative_path_from(Pathname.new(base)).to_s
  end

  # Renderiza os filhos de um bloco (para toggle, table, etc.)
  def render_children(block)
    id = block["id"]
    md = String.new
    cursor = nil
    loop do
      resp = @client.blocks.children.list(block_id: id, start_cursor: cursor)
      (resp["results"] || []).each do |child|
        md << Markdown.render_block(child, self)
      end
      cursor = resp["next_cursor"]
      break unless resp["has_more"]
    end
    md
  end

  def render_children_as_table(block)
    id = block["id"]
    rows = []
    cursor = nil
    loop do
      resp = @client.blocks.children.list(block_id: id, start_cursor: cursor)
      (resp["results"] || []).each do |row|
        next unless row["type"] == "table_row"
        cells = row.dig("table_row", "cells") || []
        rows << cells.map { |cell| Markdown.render_rich_text_array(cell) }
      end
      cursor = resp["next_cursor"]
      break unless resp["has_more"]
    end

    return "\n" if rows.empty?

    # Markdown table simples
    out = String.new
    out << "| #{rows.first.map { |c| c.empty? ? " " : c }.join(" | ")} |\n"
    out << "| #{Array.new(rows.first.size, "---").join(" | ")} |\n"
    rows[1..]&.each do |r|
      out << "| #{r.map { |c| c.empty? ? " " : c }.join(" | ")} |\n"
    end
    out << "\n\n"
    out
  end
end

# ────────────────────────────────────────────────────────────────────────────────
# Exportador principal
# ────────────────────────────────────────────────────────────────────────────────
class NotionMarkdownExporter
  def initialize(token:, out_dir:)
    @client = Notion::Client.new(token: token)
    @ctx = ExportContext.new(client: @client, root_out: out_dir)
  end

  def export!(root_input)
    root_id = Utils.extract_notion_id(root_input)
    export_page_recursive(root_id)
  end

  private

  def export_page_recursive(page_id)
    return if @ctx.visited_pages.key?(page_id)

    page = @client.pages.retrieve(page_id: page_id)
    title = extract_title(page) || "Untitled"

    out_dir = @ctx.page_dir(page_id, title)
    Utils.ensure_dir(out_dir)

    @ctx.visited_pages[page_id] = out_dir

    md = String.new
    md << "# #{title}\n\n"
    md << render_page_properties(page)

    # Blocos da página
    md << render_block_tree(page_id)

    # Escreve arquivo
    index_path = File.join(out_dir, "index.md")
    Utils.safe_write(index_path, md)

    # Recursão para child_page e child_database
    traverse_children_pages(page_id)
  end

  def extract_title(page)
    # Procura propriedade do tipo title
    props = page["properties"] || {}
    title_prop = props.values.find { |p| p["type"] == "title" }
    arr = title_prop&.dig("title") || []
    return arr.map { |r| r["plain_text"] }.join unless arr.empty?

    # Fallback: página sem title (pode ocorrer em páginas de DB)
    page.dig("url")
  end

  def render_page_properties(page)
    props = page["properties"] || {}
    out = String.new
    unless props.empty?
      out << "\n<!-- properties -->\n"
      props.each do |name, prop|
        next if prop["type"] == "title"
        val = human_property(prop)
        next if val.nil? || (val.respond_to?(:empty?) && val.empty?)
        out << "- **#{name}**: #{val}\n"
      end
      out << "\n"
    end
    out
  end

  def human_property(prop)
    case prop["type"]
    when "rich_text"
      Markdown.render_rich_text_array(prop["rich_text"]) 
    when "select"
      prop.dig("select", "name")
    when "multi_select"
      (prop["multi_select"] || []).map { |s| s["name"] }.join(", ")
    when "date"
      d = prop["date"]
      return nil unless d
      if d["end"]
        "#{d["start"]} → #{d["end"]}"
      else
        d["start"]
      end
    when "people"
      (prop["people"] || []).map { |p| p["name"] || p["id"] }.join(", ")
    when "files"
      (prop["files"] || []).map do |f|
        url = f["type"] == "external" ? f.dig("external", "url") : f.dig("file", "url")
        name = f["name"] || File.basename(URI(url).path)
        local = @ctx.download_asset(url)
        "[#{name}](#{local})"
      end.join(", ")
    when "checkbox"
      prop["checkbox"] ? "true" : "false"
    when "url", "email", "phone_number"
      prop[prop["type"]]
    when "number"
      prop["number"]
    when "relation"
      (prop["relation"] || []).map { |r| r["id"] }.join(", ")
    when "status"
      prop.dig("status", "name")
    else
      nil
    end
  end

  def render_block_tree(page_id)
    md = String.new
    cursor = nil
    @ctx.with_page_dirs(@ctx.page_dir(page_id, extract_title(@client.pages.retrieve(page_id: page_id)) || page_id)) do
      loop do
        resp = @client.blocks.children.list(block_id: page_id, start_cursor: cursor)
        (resp["results"] || []).each do |block|
          md << Markdown.render_block(block, @ctx)
        end
        cursor = resp["next_cursor"]
        break unless resp["has_more"]
      end
    end
    md
  end

  def traverse_children_pages(page_or_block_id)
    cursor = nil
    loop do
      resp = @client.blocks.children.list(block_id: page_or_block_id, start_cursor: cursor)
      (resp["results"] || []).each do |block|
        t = block["type"]
        case t
        when "child_page"
          child_id = block["id"] # o id do bloco child_page é o id da página
          export_page_recursive(child_id)
        when "child_database"
          db_id = block["id"]
          export_database_pages(db_id)
        end
      end
      cursor = resp["next_cursor"]
      break unless resp["has_more"]
    end
  end

  def export_database_pages(database_id)
    cursor = nil
    loop do
      resp = @client.databases.query(database_id: database_id, start_cursor: cursor)
      pages = resp["results"] || []
      pages.each do |p|
        export_page_recursive(p["id"])
      end
      cursor = resp["next_cursor"]
      break unless resp["has_more"]
    end
  end
end

# ────────────────────────────────────────────────────────────────────────────────
# CLI
# ────────────────────────────────────────────────────────────────────────────────
if $PROGRAM_NAME == __FILE__
  unless ENV["NOTION_TOKEN"]
    warn "Erro: defina a variável de ambiente NOTION_TOKEN com seu token da Notion API."
    exit 1
  end

  input = ARGV[0] or abort "Uso: ruby notion_dump.rb <notion_page_url_or_id> <output_dir>"
  out   = ARGV[1] || "./notion_dump"

  Utils.ensure_dir(out)

  exporter = NotionMarkdownExporter.new(token: ENV["NOTION_TOKEN"], out_dir: out)
  exporter.export!(input)

  puts "✔ Exportação concluída em: #{File.expand_path(out)}"
end
