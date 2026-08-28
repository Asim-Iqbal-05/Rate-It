# Pulled from the ECR Public mirror, not Docker Hub directly - CodeBuild
# shares egress IPs across many AWS customers' builds, which routinely
# trips Docker Hub's per-IP anonymous pull rate limit (429 Too Many
# Requests). The ECR Public Gallery mirrors official images without
# that limit.
FROM public.ecr.aws/docker/library/python:3.13-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 8000

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
