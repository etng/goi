import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'Goi 語彙',
  description: 'macOS 上的本地词典应用：一键查词、生词本、Anki 同步。',
  lang: 'zh-CN',
  base: '/goi/',
  lastUpdated: true,
  cleanUrls: true,

  head: [
    ['link', { rel: 'icon', href: '/goi/shots/icon.png' }],
    ['meta', { property: 'og:title', content: 'Goi 語彙' }],
    ['meta', { property: 'og:description', content: 'macOS 上的本地词典应用：一键查词、生词本、Anki 同步。' }],
  ],

  themeConfig: {
    nav: [
      { text: '使用指南', link: '/guide/what-is-goi', activeMatch: '/guide/' },
      { text: '下载', link: 'https://github.com/etng/goi/releases/latest' },
      { text: 'GitHub', link: 'https://github.com/etng/goi' },
    ],

    sidebar: {
      '/guide/': [
        {
          text: '开始',
          items: [
            { text: 'Goi 是什么', link: '/guide/what-is-goi' },
            { text: '安装', link: '/guide/install' },
            { text: '添加词典', link: '/guide/add-dictionaries' },
            { text: '快速上手', link: '/guide/quick-start' },
          ],
        },
        {
          text: '查词',
          items: [
            { text: '查词与切换词典', link: '/guide/lookup' },
            { text: '划词取词', link: '/guide/selection' },
            { text: '写下你的心得', link: '/guide/notes' },
          ],
        },
        {
          text: '积累',
          items: [
            { text: '生词本与熟悉度', link: '/guide/wordbook' },
            { text: '历史与统计', link: '/guide/history-stats' },
            { text: '同步到 Anki', link: '/guide/anki' },
          ],
        },
        {
          text: '其它',
          items: [
            { text: '设置', link: '/guide/settings' },
            { text: '常见问题', link: '/guide/faq' },
          ],
        },
      ],
    },

    socialLinks: [{ icon: 'github', link: 'https://github.com/etng/goi' }],

    search: { provider: 'local' },

    outline: { level: [2, 3], label: '本页目录' },
    docFooter: { prev: '上一页', next: '下一页' },
    lastUpdatedText: '最后更新',
    returnToTopLabel: '回到顶部',
    sidebarMenuLabel: '菜单',
    darkModeSwitchLabel: '外观',

    footer: {
      message: '以 GPLv3 许可证发布。',
      copyright: 'Goi 語彙 · 本地词典应用',
    },
  },
})
