import { useEffect, useState } from 'react';
import { Moon, Sun } from 'lucide-react';
import './theme.css';
type Theme = 'light' | 'dark';
const STORAGE = 'constelmec:theme';
function preferred():Theme {
  try {const stored=localStorage.getItem(STORAGE);if(stored==='light'||stored==='dark')return stored;}catch{}
  return window.matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light';
}
export default function ThemeSwitch(){
 const [theme,setTheme]=useState<Theme>(preferred);
 useEffect(()=>{
   document.documentElement.dataset.theme=theme;
   document.documentElement.style.colorScheme=theme;
   document.querySelector('meta[name="theme-color"]')?.setAttribute('content',theme==='dark'?'#081a2d':'#10263e');
 },[theme]);
 useEffect(()=>{
  const media=window.matchMedia('(prefers-color-scheme: dark)');
  const onChange=()=>{try{if(localStorage.getItem(STORAGE))return;}catch{}setTheme(media.matches?'dark':'light');};
  media.addEventListener('change',onChange);
  return()=>media.removeEventListener('change',onChange);
 },[]);
 const toggle=()=>setTheme(current=>{const next=current==='light'?'dark':'light';try{localStorage.setItem(STORAGE,next);}catch{}return next;});
 return <button type="button" className="constelmec-theme-switch" onClick={toggle} aria-label={theme==='dark'?'Activar modo claro':'Activar modo oscuro'} title={theme==='dark'?'Cambiar a modo claro':'Cambiar a modo oscuro'}>{theme==='dark'?<Sun size={18}/>:<Moon size={18}/>}<span>{theme==='dark'?'Claro':'Oscuro'}</span></button>;
}
