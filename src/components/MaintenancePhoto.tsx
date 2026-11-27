import {useEffect,useState} from 'react';
import {supabase} from '../lib/supabase';

type PhotoPreview = {path: string; url: string} | {path: string; failed: true};

export default function MaintenancePhoto({bucket,path,phase}: {bucket:string;path:string;phase:string}) {
  const [preview,setPreview] = useState<PhotoPreview | null>(null);

  useEffect(() => {
    let active = true;
    let objectUrl: string | undefined;
    const load = async () => {
      try {
        const {data,error} = await supabase!.storage.from(bucket).download(path);
        if (!active) return;
        if (error || !data) {
          setPreview({path,failed:true});
          return;
        }
        objectUrl = URL.createObjectURL(data);
        setPreview({path,url:objectUrl});
      } catch {
        if (active) setPreview({path,failed:true});
      }
    };
    void load();
    return () => {
      active = false;
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
  },[bucket,path]);

  if (preview?.path !== path) return <small>Cargando foto…</small>;
  if ('failed' in preview) return <small role="status">Foto no disponible</small>;
  return <a href={preview.url} target="_blank" rel="noopener noreferrer"
    style={{display:'inline-block',width:52,height:52,overflow:'hidden',verticalAlign:'middle',marginRight:4,marginTop:4}}>
    <img src={preview.url} alt={phase} style={{width:'100%',height:'100%',objectFit:'cover',display:'block'}}/>
  </a>;
}
