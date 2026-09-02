from datetime import datetime
from sqlalchemy import Column,Integer,String,DateTime,Text
from .database import Base
class Lead(Base):
    __tablename__="leads"
    id=Column(Integer,primary_key=True)
    name=Column(String,default="New Customer")
    phone=Column(String,index=True)
    requirement=Column(Text,default="")
    stage=Column(String,default="new")
    score=Column(Integer,default=20)
    created_at=Column(DateTime,default=datetime.utcnow)
