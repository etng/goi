<script setup>
import { data } from './support.data.js'
</script>

# 支持 Goi

Goi 是一个人利用业余时间做的免费开源软件，没有广告、不卖会员、不收集你的数据。
从解析各种词典格式、打磨查词体验，到写这份手册、画图标，背后是不少个人时间和成本。

如果 Goi 帮你查词更顺手、让你更愿意积累生词，欢迎请作者喝杯咖啡 ☕️——这会实实在在
地鼓励它继续做下去、把[计划中的功能](/guide/what-is-goi#和常见词典软件对比)一个个补上。

## 扫码捐赠

<div class="qr-row">
  <figure>
    <img src="/shots/wechat.png" alt="微信支付" />
    <figcaption>微信支付</figcaption>
  </figure>
  <figure>
    <img src="/shots/alipay.jpg" alt="支付宝" />
    <figcaption>支付宝</figcaption>
  </figure>
</div>

## 登上捐款墙

捐赠之后，如果你愿意留名，可以[**新建一个捐赠 issue**](https://github.com/etng/goi/issues/new?template=donation.yml&labels=donation)，
填写你想显示的名字和金额（可选留言）。作者**核实到账后**会把它加进下面的捐款墙——
所以名单都是真实确认过的，不用担心被人乱刷。

## 捐款墙

<div v-if="data.count" class="donor-wall">
  <p class="donor-summary">感谢这 {{ data.count }} 位朋友的支持 💛</p>
  <ul class="donor-list">
    <li v-for="d in data.donors" :key="d.name + d.date">
      <span class="donor-name">{{ d.name }}</span>
      <span class="donor-amount">¥{{ d.amount }}</span>
      <span v-if="d.message" class="donor-msg">“{{ d.message }}”</span>
    </li>
  </ul>
</div>
<p v-else class="donor-empty">还没有人上墙——你可以是第一个 🙂</p>

<style scoped>
.qr-row { display: flex; gap: 32px; flex-wrap: wrap; margin: 20px 0; }
.qr-row figure { margin: 0; text-align: center; }
.qr-row img { width: 220px; height: 220px; border-radius: 10px; background: #fff; }
.qr-row figcaption { margin-top: 8px; color: var(--vp-c-text-2); font-size: 14px; }
.donor-summary { color: var(--vp-c-text-2); }
.donor-list { list-style: none; padding: 0; display: flex; flex-direction: column; gap: 8px; }
.donor-list li { display: flex; align-items: baseline; gap: 12px; padding: 8px 12px;
  border: 1px solid var(--vp-c-divider); border-radius: 8px; }
.donor-name { font-weight: 600; }
.donor-amount { color: var(--vp-c-brand-1); font-variant-numeric: tabular-nums; }
.donor-msg { color: var(--vp-c-text-2); font-size: 14px; }
.donor-empty { color: var(--vp-c-text-2); }
</style>
