import React, { useState } from 'react'

function Nav({ current, setCurrent }) {
  const items = [
    { id: 'home', label: 'Home' },
    { id: 'weekly', label: 'Dispatch' },
    { id: 'archive', label: 'Archive' },
    { id: 'trackers', label: 'Dockets' },
    { id: 'rumors', label: 'Rumor Control' },
    { id: 'subscribe', label: 'Join CrewSignal' },
    { id: 'privacy', label: 'Privacy' },
  ]
  return (
    <nav style={{position:'sticky',top:0,backdropFilter:'blur(6px)',background:'rgba(255,255,255,0.8)',borderBottom:'1px solid #e5e7eb',zIndex:50}}>
      <div style={{maxWidth:960,margin:'0 auto',padding:'12px 16px',display:'flex',justifyContent:'space-between',alignItems:'center'}}>
        <div style={{fontWeight:800,fontSize:22,color:'#111827'}}>CrewSignal</div>
        <ul style={{display:'flex',gap:8,flexWrap:'wrap'}}>
          {items.map(it => (
            <li key={it.id}>
              <button onClick={()=>setCurrent(it.id)}
                style={{padding:'8px 12px',borderRadius:9999,fontSize:14,transition:'all 150ms',background: current===it.id ? '#2563eb' : 'transparent',color: current===it.id ? '#fff' : '#374151',border: current===it.id ? '1px solid #2563eb' : '1px solid transparent'}}>
                {it.label}
              </button>
            </li>
          ))}
        </ul>
      </div>
    </nav>
  )
}

function Section({children}){ return <section style={{maxWidth:896,margin:'0 auto',padding:'40px 16px'}}>{children}</section> }

function Hero({ setCurrent }) {
  return (
    <div style={{background:'linear-gradient(#f9fafb, #ffffff)'}}>
      <Section>
        <div style={{display:'grid',gap:24}}>
          <div>
            <h1 style={{fontSize:44,fontWeight:800,color:'#111827',lineHeight:1.1}}>CrewSignal</h1>
            <p style={{marginTop:8,fontSize:18,color:'#1d4ed8',fontWeight:600}}>Clear, verified updates on airline mergers, mediation, and governance.</p>
            <p style={{marginTop:16,color:'#4b5563'}}>A weekly informational dispatch built to keep airline professionals accurately informed — without speculation or noise.</p>
            <div style={{marginTop:16,display:'flex',gap:12}}>
              <button onClick={()=>setCurrent('weekly')} style={{padding:'12px 16px',borderRadius:12,background:'#2563eb',color:'#fff',border:'none'}}>Read this week’s dispatch</button>
              <button onClick={()=>setCurrent('subscribe')} style={{padding:'12px 16px',borderRadius:12,background:'transparent',color:'#2563eb',border:'1px solid #2563eb'}}>Join CrewSignal</button>
            </div>
          </div>
          <div style={{border:'1px solid #e5e7eb',borderRadius:16,padding:16,background:'#fff'}}>
            <ul style={{color:'#374151',lineHeight:1.8,fontSize:14}}>
              <li>• DOJ/DOT merger & regulatory updates</li>
              <li>• NMB mediation docket tracking</li>
              <li>• Governance & union structure analysis</li>
              <li>• Financial context (LM-2)</li>
            </ul>
          </div>
        </div>
      </Section>
    </div>
  )
}

function Weekly(){ return <Section><h2 style={{fontSize:28,fontWeight:800}}>This Week’s CrewSignal Dispatch</h2><p style={{fontSize:12,color:'#6b7280',marginTop:4}}>Updated weekly; archive below.</p></Section> }
function Archive(){ return <Section><h2 style={{fontSize:28,fontWeight:800}}>Archive</h2></Section> }
function Trackers(){ return <Section><h2 style={{fontSize:28,fontWeight:800}}>Dockets & Trackers</h2></Section> }
function Rumors(){ return <Section><h2 style={{fontSize:28,fontWeight:800}}>Rumor Control</h2></Section> }

function Subscribe(){
  const [form, setForm] = useState({ firstName: '', lastName: '', email: '', airline: '', base: '', phone: '', consent: false })
  const [status, setStatus] = useState('idle')
  const submit = async (e) => {
    e.preventDefault()
    try {
      setStatus('loading')
      const res = await fetch('/.netlify/functions/subscribe',{ method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(form) })
      if(!res.ok) throw new Error('bad')
      setStatus('success')
    } catch { setStatus('error') }
  }
  return (
    <Section>
      <h2 style={{fontSize:28,fontWeight:800}}>Join CrewSignal</h2>
      <form onSubmit={submit} style={{marginTop:16,background:'#fff',border:'1px solid #e5e7eb',borderRadius:16,padding:24,display:'grid',gap:16}}>
        <div style={{display:'grid',gap:12,gridTemplateColumns:'repeat(auto-fit,minmax(200px,1fr))'}}>
          <div><label style={{fontSize:12,color:'#6b7280'}}>First name</label><input value={form.firstName} onChange={(e)=>setForm({...form, firstName:e.target.value})} required style={{marginTop:4,width:'100%',border:'1px solid #d1d5db',borderRadius:12,padding:'8px 12px'}}/></div>
          <div><label style={{fontSize:12,color:'#6b7280'}}>Last name</label><input value={form.lastName} onChange={(e)=>setForm({...form, lastName:e.target.value})} required style={{marginTop:4,width:'100%',border:'1px solid #d1d5db',borderRadius:12,padding:'8px 12px'}}/></div>
        </div>
        <div><label style={{fontSize:12,color:'#6b7280'}}>Personal email</label><input type='email' value={form.email} onChange={(e)=>setForm({...form, email:e.target.value})} required style={{marginTop:4,width:'100%',border:'1px solid #d1d5db',borderRadius:12,padding:'8px 12px'}}/></div>
        <div style={{display:'grid',gap:12,gridTemplateColumns:'repeat(auto-fit,minmax(200px,1fr))'}}>
          <div><label style={{fontSize:12,color:'#6b7280'}}>Airline</label><input value={form.airline} onChange={(e)=>setForm({...form, airline:e.target.value})} style={{marginTop:4,width:'100%',border:'1px solid #d1d5db',borderRadius:12,padding:'8px 12px'}}/></div>
          <div><label style={{fontSize:12,color:'#6b7280'}}>Base / Domicile</label><input value={form.base} onChange={(e)=>setForm({...form, base:e.target.value})} style={{marginTop:4,width:'100%',border:'1px solid #d1d5db',borderRadius:12,padding:'8px 12px'}}/></div>
          <div><label style={{fontSize:12,color:'#6b7280'}}>Phone (optional)</label><input value={form.phone} onChange={(e)=>setForm({...form, phone:e.target.value})} style={{marginTop:4,width:'100%',border:'1px solid #d1d5db',borderRadius:12,padding:'8px 12px'}}/></div>
        </div>
        <div style={{display:'flex',gap:8,alignItems:'flex-start'}}>
          <input id='consent' type='checkbox' checked={form.consent} onChange={(e)=>setForm({...form, consent:e.target.checked})} required style={{marginTop:3}}/>
          <label htmlFor='consent' style={{fontSize:14,color:'#374151'}}>I agree to receive CrewSignal updates. I can opt out anytime.</label>
        </div>
        <button type='submit' disabled={status==='loading'} style={{padding:'12px 16px',borderRadius:12,background:'#2563eb',color:'#fff',border:'none'}}>
          {status==='loading'?'Submitting…':status==='success'?'Added!':'Subscribe'}
        </button>
        {status==='error' && <p style={{fontSize:12,color:'#dc2626'}}>Something went wrong. Try again.</p>}
      </form>
    </Section>
  )
}

function Privacy(){ return <Section><h2 style={{fontSize:28,fontWeight:800}}>Privacy & Data Use</h2></Section> }

export default function App(){
  const [current, setCurrent] = useState('home')
  return (
    <main style={{minHeight:'100vh',background:'#f9fafb',color:'#111827'}}>
      <Nav current={current} setCurrent={setCurrent} />
      {current === 'home' && <Hero setCurrent={setCurrent} />}
      {current === 'weekly' && <Weekly />}
      {current === 'archive' && <Archive />}
      {current === 'trackers' && <Trackers />}
      {current === 'rumors' && <Rumors />}
      {current === 'subscribe' && <Subscribe />}
      {current === 'privacy' && <Privacy />}
      <footer style={{borderTop:'1px solid #e5e7eb',marginTop:32,background:'rgba(255,255,255,0.6)'}}>
        <div style={{maxWidth:960,margin:'0 auto',padding:'20px 16px',display:'flex',justifyContent:'space-between',fontSize:14,color:'#6b7280'}}>
          <div>© {new Date().getFullYear()} CrewSignal — Educational & informational only.</div>
          <button onClick={()=>setCurrent('privacy')} style={{textDecoration:'underline',background:'none',border:'none',color:'#374151',cursor:'pointer'}}>Privacy</button>
        </div>
      </footer>
    </main>
  )
}
