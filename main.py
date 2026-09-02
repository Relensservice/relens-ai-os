import os
from pathlib import Path
from fastapi import FastAPI,Depends
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from sqlalchemy.orm import Session
from .database import Base,engine,get_db
from .models import Lead
Base.metadata.create_all(bind=engine)
app=FastAPI(title="ReLens AI OS V5")
BASE=Path(__file__).resolve().parent.parent
app.mount("/static",StaticFiles(directory=BASE/"static"),name="static")
class Chat(BaseModel): message:str
class LeadIn(BaseModel): name:str;phone:str;requirement:str=""
def ai_reply(m):
    m=m.lower()
    if "book" in m or "appointment" in m:return "I'd be happy to help. Please use the Book Now button to choose your convenient appointment slot."
    if "lens" in m or "power" in m:return "We can help with premium lens replacement 👓 Do you have your latest prescription and your favourite frame?"
    if "home" in m:return "ReLens can help with convenient home-service enquiries. Please share your area and service needed."
    return "Hello! Welcome to ReLens 👋 I can help with lens replacement, frame care, home service and appointments."
@app.get("/")
def home(): return FileResponse(BASE/"static"/"index.html")
@app.get("/dashboard")
def dashpage(): return FileResponse(BASE/"static"/"dashboard.html")
@app.post("/api/chat")
def chat(d:Chat): return {"reply":ai_reply(d.message)}
@app.post("/api/leads")
def lead(d:LeadIn,db:Session=Depends(get_db)):
    t=d.requirement.lower();score=40;stage="cold"
    if any(x in t for x in ["book","appointment","urgent","today"]):score,stage=85,"hot"
    elif any(x in t for x in ["lens","home","repair","price"]):score,stage=65,"warm"
    x=Lead(name=d.name,phone=d.phone,requirement=d.requirement,score=score,stage=stage)
    db.add(x);db.commit();db.refresh(x)
    return {"success":True,"id":x.id,"score":score,"stage":stage}
@app.get("/api/dashboard")
def dashboard(db:Session=Depends(get_db)):
    rows=db.query(Lead).order_by(Lead.id.desc()).all();p={}
    for x in rows:p[x.stage]=p.get(x.stage,0)+1
    return {"total":len(rows),"hot":p.get("hot",0),"warm":p.get("warm",0),"latest":[{"name":x.name,"phone":x.phone,"requirement":x.requirement,"stage":x.stage,"score":x.score} for x in rows[:10]]}
