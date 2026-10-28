from fastapi import FastAPI

app = FastAPI(title="Ahvaanam API")


@app.get("/health")
def health():
    return {"status": "ok", "service": "ahvaanam-api"}


@app.get("/")
def root():
    return {"message": "Welcome to Ahvaanam"}