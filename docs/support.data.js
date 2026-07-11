import { defineLoader } from 'vitepress'

// Build-time loader: pulls GitHub issues labelled `donor-wall` and turns them
// into the donor list. Only the maintainer adds that label (after confirming
// a donation), so the wall can't be spammed. Anonymous fetch works locally;
// CI passes GITHUB_TOKEN to avoid rate limits.
const REPO = 'etng/goi'

export default defineLoader({
  async load() {
    const headers = {
      Accept: 'application/vnd.github+json',
      'User-Agent': 'goi-docs',
    }
    if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`

    let issues = []
    try {
      const res = await fetch(
        `https://api.github.com/repos/${REPO}/issues?labels=donor-wall&state=all&per_page=100`,
        { headers },
      )
      if (res.ok) issues = await res.json()
    } catch {
      // offline / rate-limited — render an empty wall rather than fail the build
    }

    const donors = issues
      .filter((it) => !it.pull_request)
      .map((it) => parseIssue(it))
      .filter((d) => d && d.name)

    donors.sort((a, b) => b.amount - a.amount || a.date.localeCompare(b.date))

    const total = donors.reduce((s, d) => s + (d.amount || 0), 0)
    return { donors, total, count: donors.length }
  },
})

function section(body, title) {
  // GitHub issue-form bodies render each field as "### <title>\n\n<value>"
  const re = new RegExp(`###\\s*${title}[^\\n]*\\n+([\\s\\S]*?)(?=\\n###\\s|$)`, 'i')
  const m = body.match(re)
  return m ? m[1].trim() : ''
}

function parseIssue(issue) {
  const body = issue.body || ''
  let name = section(body, '显示名称')
  let amountRaw = section(body, '金额')
  const message = section(body, '留言')

  // fallback: use the issue title if the form field is empty
  if (!name) name = (issue.title || '').replace(/^\[?捐赠\]?[:：]?\s*/i, '').trim()

  const amountMatch = amountRaw.match(/[\d.]+/)
  const amount = amountMatch ? parseFloat(amountMatch[0]) : 0

  if (name.toLowerCase() === '_no response_' || !name) return null
  return {
    name,
    amount,
    message: message && message.toLowerCase() !== '_no response_' ? message : '',
    date: (issue.created_at || '').slice(0, 10),
  }
}
