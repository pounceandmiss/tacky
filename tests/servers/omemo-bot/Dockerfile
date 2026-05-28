FROM python:3.11-slim

RUN python -m venv /opt/bot-venv \
    && /opt/bot-venv/bin/pip install --no-cache-dir --upgrade pip

COPY requirements.txt /opt/requirements.txt
RUN /opt/bot-venv/bin/pip install --no-cache-dir -r /opt/requirements.txt

COPY bot.py /opt/bot.py
COPY smoke.py /opt/smoke.py

ENV PYTHONUNBUFFERED=1
CMD ["/opt/bot-venv/bin/python", "/opt/bot.py"]
