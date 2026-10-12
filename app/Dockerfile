FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
# The version, and the fault settings a lab image can bake in.
ARG APP_VERSION=dev
ARG ERROR_RATE=0
ARG DELAY_MS=0
ENV APP_VERSION=$APP_VERSION ERROR_RATE=$ERROR_RATE DELAY_MS=$DELAY_MS
USER 65534
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
