import { chromium, devices } from '@playwright/test';
import fs from 'node:fs/promises';
const BASE=process.env.AUDIT_URL||'http://127.0.0.1:4173';
const sizes=[
  {name:'small-320',width:320,height:640},
  {name:'iphone-se',width:375,height:667},
  {name:'android-360',width:360,height:800},
  {name:'android-393',width:393,height:852},
  {name:'large-430',width:430,height:932},
  {name:'tablet-768',width:768,height:1024},
  {name:'desktop-1280',width:1280,height:800},
];
const browser=await chromium.launch({headless:true});
const issues=[];const summary=[];
await fs.mkdir('artifacts/design-audit',{recursive:true});
const esc=s=>s.replace(/[^a-z0-9_-]/gi,'_');
async function audit(page,label,viewport,theme){
 await page.waitForTimeout(150);
 const result=await page.evaluate(()=>{
  const selectors=['button','a[href]','input','select','textarea'];
  const visible=el=>{const r=el.getBoundingClientRect(),st=getComputedStyle(el);return r.width>0&&r.height>0&&st.visibility!=='hidden'&&st.display!=='none'};
  const elements=[...document.querySelectorAll(selectors.join(','))].filter(visible);
  const interactive=elements.map(el=>{const r=el.getBoundingClientRect();return {name:(el.getAttribute('aria-label')||el.textContent||el.tagName).trim().slice(0,55),x:r.x,y:r.y,w:r.width,h:r.height}});
  const horizontal=document.documentElement.scrollWidth>innerWidth+2;
  const clipped=interactive.filter(e=>e.x < -2||e.x+e.w>innerWidth+2);
  const small=interactive.filter(e=>e.w<28||e.h<28);
  const overlaps=[];
  for(let i=0;i<interactive.length;i++)for(let j=i+1;j<interactive.length;j++){
   const a=interactive[i],b=interactive[j];
   const ix=Math.max(0,Math.min(a.x+a.w,b.x+b.w)-Math.max(a.x,b.x));
   const iy=Math.max(0,Math.min(a.y+a.h,b.y+b.h)-Math.max(a.y,b.y));
   if(ix*iy>Math.min(a.w*a.h,b.w*b.h)*.25)overlaps.push([a.name,b.name]);
  }
  return {horizontal,clipped,small,overlaps,scrollWidth:document.documentElement.scrollWidth,viewport:innerWidth};
 });
 const prefix=esc(label+'-'+viewport.name+'-'+theme);
 await page.screenshot({path:'artifacts/design-audit/'+prefix+'.png',fullPage:true,animations:'disabled'});
 const findings=[];
 if(result.horizontal)findings.push('Horizontal overflow: '+result.scrollWidth+' > '+result.viewport);
 if(result.clipped.length)findings.push('Clipped controls: '+JSON.stringify(result.clipped));
 if(result.overlaps.length)findings.push('Overlapping controls: '+JSON.stringify(result.overlaps.slice(0,8)));
 // Touch targets under 28px are recorded for manual review; 44px remains the design goal.
 if(result.small.length)findings.push('Small interactive targets: '+JSON.stringify(result.small.slice(0,8)));
 summary.push({screen:label,viewport:viewport.name,theme,findings:findings.length});
 for(const finding of findings)issues.push({screen:label,viewport:viewport.name,theme,finding});
}
for(const viewport of sizes)for(const theme of ['light','dark']){
 const context=await browser.newContext({viewport:{width:viewport.width,height:viewport.height},deviceScaleFactor:1,hasTouch:true,isMobile:viewport.width<768,colorScheme:theme});
 const page=await context.newPage();
 const errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 await page.goto(BASE,{waitUntil:'networkidle'});
 await audit(page,'login',viewport,theme);
 const demo=page.getByRole('button',{name:/Explorar demostración/i});
 if(await demo.count()){
  await demo.first().click();
  await audit(page,'technician-home',viewport,theme);
  const customer=page.getByRole('button',{name:/Cliente/i});
  if(await customer.count()){
   await customer.last().click();
   await audit(page,'customer-home',viewport,theme);
  }else issues.push({screen:'customer-home',viewport:viewport.name,theme,finding:'Customer role toggle not found'});
  const technician=page.getByRole('button',{name:/Técnico/i});
  if(await technician.count())await technician.last().click();
  const scan=page.getByRole('button',{name:/Escanear QR/i});
  if(await scan.count()){
   await scan.first().click();
   await audit(page,'gate-detail',viewport,theme);
   const start=page.getByRole('button',{name:/Iniciar inspección/i});
   if(await start.count()){
    await start.first().click();
    await audit(page,'inspection',viewport,theme);
   }
  }
 }else issues.push({screen:'demo',viewport:viewport.name,theme,finding:'Demo entry not found'});
 for(const error of errors)issues.push({screen:'runtime',viewport:viewport.name,theme,finding:error});
 await context.close();
}
await browser.close();
await fs.writeFile('artifacts/design-audit/report.json',JSON.stringify({summary,issues},null,2));
let md='# Constelmec design audit\n\nAutomated viewport/overlap audit. Screenshots in artifacts/design-audit.\n\n';
md+='| Screen | Viewport | Theme | Findings |\n|---|---|---|---:|\n';
for(const s of summary)md+=`| ${s.screen} | ${s.viewport} | ${s.theme} | ${s.findings} |\n`;
md+='\n## Findings\n';
for(const i of issues)md+=`- **${i.screen} / ${i.viewport} / ${i.theme}:** ${i.finding}\n`;
await fs.writeFile('artifacts/design-audit/report.md',md);
console.log('Audited '+summary.length+' screen/theme/viewport combinations; findings: '+issues.length);
if(issues.some(i=>/Horizontal overflow|Clipped controls|Overlapping controls|not found|runtime/i.test(i.finding)))process.exitCode=1;
